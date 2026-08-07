defmodule BeamLisp.Wave23CodeVersionTest do
  # Stored closures must survive namespace redefinition.
  #
  # Every `defn` regenerates the namespace module, and the BEAM keeps
  # exactly two versions of a module — loading a third purges the oldest.
  # If a fn's body (and the closures it creates) lived in the regenerated
  # module, a closure stored in a `def` would become a BadFunctionError
  # once enough later `defn`s had churned the module. The fix moves each
  # defn's real code into an immutable body module and leaves only thin
  # shims in the namespace module, so closures keep pointing at code that
  # is never purged.
  #
  # These tests pin that guarantee, plus the two properties it must not
  # trade away: call sites still link to the namespace module directly,
  # and hot code replacement still works.
  use ExUnit.Case, async: false

  @moduletag :wave23

  defp eval(ns, source) do
    BeamLisp.init()
    BeamLisp.Env.in_ns(ns)
    BeamLisp.Compiler.eval_string(source, BeamLisp.Compiler.new_env(ns))
  end

  test "a stored closure survives three later defns (the original repro)" do
    out =
      ExUnit.CaptureIO.capture_io(fn ->
        eval("w23repro", """
        (ns w23repro)
        (defn mk [n] (fn [x] (+ x n)))
        (def add5 (mk 5))
        (println (str "immediately: " (add5 1)))
        (defn other [] 1)
        (defn other2 [] 2)
        (defn other3 [] 3)
        (println (str "after more defns: " (add5 1)))
        """)
      end)

    assert out =~ "immediately: 6"
    assert out =~ "after more defns: 6"

    # The closure itself still returns 6 — the repro printed it, but the
    # value is the point: the stored closure survived the three defns.
    assert eval("w23repro", "(add5 1)") == 6
  end

  test "a closure survives ten or more subsequent defns" do
    result =
      eval("w23many", """
      (ns w23many)
      (defn mk [n] (fn [x] (+ x n)))
      (def add7 (mk 7))
      (defn d1 [] 1)
      (defn d2 [] 2)
      (defn d3 [] 3)
      (defn d4 [] 4)
      (defn d5 [] 5)
      (defn d6 [] 6)
      (defn d7 [] 7)
      (defn d8 [] 8)
      (defn d9 [] 9)
      (defn d10 [] 10)
      (add7 1)
      """)

    assert result == 8
  end

  test "a closure survives redefining the fn that made it" do
    # Redefining `mk` three times would purge the version that produced
    # the stored closure if its code lived in the regenerated module.
    result =
      eval("w23redef", """
      (ns w23redef)
      (defn mk [n] (fn [x] (+ x n)))
      (def add3 (mk 3))
      (defn mk [n] (fn [x] (+ x n 1000)))
      (defn mk [n] (fn [x] (+ x n 2000)))
      (defn mk [n] (fn [x] (+ x n 3000)))
      (add3 1)
      """)

    assert result == 4
  end

  test "a closure from a multi-arity fn survives later defns" do
    result =
      eval("w23arity", """
      (ns w23arity)
      (defn mk [n] (fn [x] (+ x n)))
      (defn mk [n m] (fn [x] (+ x n m)))
      (def add10 (mk 4 6))
      (defn f1 [] 1)
      (defn f2 [] 2)
      (defn f3 [] 3)
      (add10 1)
      """)

    assert result == 11
  end

  test "a closure from a variadic fn survives later defns" do
    result =
      eval("w23vari", """
      (ns w23vari)
      (defn vmk [& ns] (fn [x] (reduce + x ns)))
      (def sum (vmk 1 2 3))
      (defn g1 [] 1)
      (defn g2 [] 2)
      (defn g3 [] 3)
      (sum 10)
      """)

    assert result == 16
  end

  test "call sites still link to the namespace module, not a body module" do
    eval("w23link", """
    (ns w23link)
    (defn f [x] (+ x 1))
    """)

    {:ok, {mod, _fixed, _variadic}} = BeamLisp.Env.link("w23link", "f")

    # The link metadata must name the namespace module (so call sites emit
    # `BeamLisp.Ns.<Ns>.f(...)` directly), not an opaque body module.
    assert mod == BeamLisp.Link.module_for("w23link")
    assert mod != BeamLisp.Ns.Fn
    assert apply(mod, :f, [1]) == 2
  end

  test "an existing closure sees a redefined fn (hot code replacement)" do
    eval("w23hot", """
    (ns w23hot)
    (defn report [] "v1")
    (def caller (fn [] (report)))
    """)

    assert eval("w23hot", "(caller)") == "v1"

    # The pre-existing `caller` closure was built before this redefinition;
    # its call to `report` must resolve to the new code, not the old.
    eval("w23hot", ~S/(defn report [] "v2")/)
    assert eval("w23hot", "(caller)") == "v2"
  end

  test "a running process observes a redefinition mid-flight" do
    eval("w23hotloop", """
    (ns w23hotloop)
    (defn version [] "v1")
    """)

    # `Env.current_ns` is a single global Agent, so a looping process that
    # evaluates source would fight every other test for it. Call the linked
    # fn directly — that is what a real long-running process does, and it
    # is the path hot-swap has to work on.
    {:ok, {mod, fixed, _variadic}} = BeamLisp.Env.link("w23hotloop", "version")
    fname = Map.fetch!(fixed, 0)
    test_pid = self()

    looper =
      spawn(fn ->
        Enum.each(1..120, fn _ ->
          send(test_pid, {:saw, apply(mod, fname, [])})
          Process.sleep(10)
        end)
      end)

    assert_receive {:saw, "v1"}, 2_000

    eval("w23hotloop", ~S/(defn version [] "v2")/)

    # The SAME process, never restarted, must start seeing the new
    # definition. Only the code moved; its in-flight state is untouched.
    assert_receive {:saw, "v2"}, 3_000

    Process.exit(looper, :kill)
  end
end
