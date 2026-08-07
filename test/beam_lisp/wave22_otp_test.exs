defmodule BeamLisp.Wave22OTPTest do
  # Supervision, hot code replacement and bounded tracing.
  #
  # Restart tests race by nature: killing a child and asking for the new
  # pid are separate events, and the supervisor sits between them. Every
  # wait here POLLS with a deadline rather than sleeping a hopeful
  # interval — a flaky test is worse than an absent one, because it
  # teaches you to ignore a red suite.
  use ExUnit.Case, async: false

  @moduletag :wave22

  defp eval(ns, source) do
    BeamLisp.init()
    # `current_ns` is process-global and outlives a single evaluation, so
    # a test that does not claim its namespace inherits whichever one ran
    # before it. Claim it explicitly rather than depending on test order.
    BeamLisp.Env.in_ns(ns)
    BeamLisp.Compiler.eval_string(source, BeamLisp.Compiler.new_env(ns))
  end

  setup do
    # A test that fails mid-trace would otherwise leave :dbg installed and
    # cascade into every later trace test.
    on_exit(fn -> BeamLisp.Trace.untrace(nil, "cleanup") end)
    :ok
  end

  # Poll until `fun` returns a truthy value or the deadline passes.
  defp until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_until(fun, deadline)
  end

  defp do_until(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_until(fun, deadline)
        else
          nil
        end

      false ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_until(fun, deadline)
        else
          false
        end

      value ->
        value
    end
  end

  # The module/function a var currently links to. Resolving once and
  # calling through it is exactly what a long-running process does.
  defp greet_link(ns) do
    {:ok, {mod, fixed, _variadic}} = BeamLisp.Env.link(ns, "greet")
    {mod, Map.fetch!(fixed, 0)}
  end

  defp child_pid(sup, id) do
    until(fn ->
      case List.keyfind(Supervisor.which_children(sup), id, 0) do
        {^id, pid, _type, _mods} when is_pid(pid) -> pid
        _ -> nil
      end
    end)
  end

  describe "supervision trees" do
    test "a killed child comes back with a new pid" do
      sup =
        eval("w22sup1", """
        (ns w22sup1)
        (supervise :one-for-one [(worker :w (fn [] (Process/sleep 60000)))])
        """)

      first = child_pid(sup, :w)
      assert is_pid(first)

      Process.exit(first, :kill)

      second = until(fn -> with p when is_pid(p) <- child_pid(sup, :w), do: p != first && p end)

      assert is_pid(second)
      assert second != first

      Supervisor.stop(sup)
    end

    test "which_children and count_children report the tree" do
      sup =
        eval("w22sup2", """
        (ns w22sup2)
        (supervise :one-for-one [(worker :a (fn [] (Process/sleep 60000)))
                                 (worker :b (fn [] (Process/sleep 60000)))])
        """)

      assert %{active: 2, workers: 2, specs: 2} = Supervisor.count_children(sup)
      assert length(Supervisor.which_children(sup)) == 2

      Supervisor.stop(sup)
    end

    test ":temporary children are not restarted" do
      sup =
        eval("w22sup3", """
        (ns w22sup3)
        (supervise :one-for-one
          [(worker :t (fn [] (Process/sleep 60000)) {:restart :temporary})])
        """)

      pid = child_pid(sup, :t)
      Process.exit(pid, :kill)

      # OTP does not merely leave a :temporary child dead — it drops the
      # spec entirely, so the child disappears from the tree rather than
      # lingering as :undefined the way a :transient one would.
      assert until(fn -> Supervisor.which_children(sup) == [] || nil end)
      assert %{active: 0, specs: 0} = Supervisor.count_children(sup)

      Supervisor.stop(sup)
    end

    test ":one-for-all restarts a sibling when one child dies" do
      sup =
        eval("w22sup4", """
        (ns w22sup4)
        (supervise :one-for-all [(worker :a (fn [] (Process/sleep 60000)))
                                 (worker :b (fn [] (Process/sleep 60000)))])
        """)

      a1 = child_pid(sup, :a)
      b1 = child_pid(sup, :b)

      Process.exit(a1, :kill)

      # The sibling is restarted too — that is what distinguishes
      # :one-for-all from :one-for-one, and it is the only observable
      # difference between the two strategies.
      b2 = until(fn -> with p when is_pid(p) <- child_pid(sup, :b), do: p != b1 && p end)

      assert is_pid(b2)
      assert b2 != b1

      Supervisor.stop(sup)
    end
  end

  describe "hot code replacement" do
    test "a running process observes a redefinition mid-flight" do
      # This is the BEAM capability no other Lisp host offers. It already
      # worked as a consequence of var linking; the test is what turns it
      # from an accident into a guarantee.
      eval("w22hot", """
      (ns w22hot)
      (defn greet [] "v1")
      """)

      test_pid = self()

      # `Env.current_ns` is a single global Agent, so a looping process
      # that evaluates source would fight every other test for it. Call
      # the linked fn directly instead: that is what a real long-running
      # process does anyway, and it is the path hot-swap has to work on.
      {mod, fname} = greet_link("w22hot")

      looper =
        spawn(fn ->
          Enum.each(1..60, fn _ ->
            send(test_pid, {:saw, apply(mod, fname, [])})
            Process.sleep(20)
          end)
        end)

      assert_receive {:saw, "v1"}, 2_000

      eval("w22hot", ~S/(defn greet [] "v2")/)

      # The SAME process, never restarted, must start seeing the new
      # definition. Its in-flight state is untouched — only the code moved.
      assert_receive {:saw, "v2"}, 3_000

      Process.exit(looper, :kill)
    end
  end

  describe "tracing" do
    test "trace captures calls and untrace stops it" do
      assert eval("w22tr", """
             (ns w22tr)
             (defn work [x] (* x 2))
             (def seen (atom []))
             (trace 'work (fn [call] (swap! seen conj call)))
             (work 1)
             (work 2)
             (Process/sleep 200)
             (untrace 'work)
             (work 3)
             (Process/sleep 200)
             (count @seen)
             """) == 2
    end

    test "the count cap engages so a trace cannot run away" do
      # :dbg can take a production node down under load. The cap is the
      # difference between a tool and a footgun, so it is asserted rather
      # than trusted.
      assert eval("w22cap", """
             (ns w22cap)
             (defn tick [x] x)
             (def hits (atom 0))
             (trace 'tick (fn [_call] (swap! hits inc)) {:max-calls 3})
             (doall (map tick (range 20)))
             (Process/sleep 300)
             (untrace 'tick)
             @hits
             """) == 3
    end
  end
end
