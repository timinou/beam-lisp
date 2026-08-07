defmodule BeamLisp.Wave22ServerTest do
  # `defserver` must produce a GENUINE `:gen_server`, not a lookalike.
  #
  # That distinction is the whole premise of the wave: the reason to put
  # a Lisp on the BEAM is the BEAM, so a server that `:observer`,
  # `Supervisor` and `:sys` do not recognise would be worth nothing. Every
  # test here therefore pokes the generated module with real OTP tooling
  # rather than with beam-lisp's own client fns.
  use ExUnit.Case, async: false

  @moduletag :wave22

  defp eval(ns, source) do
    BeamLisp.init()
    BeamLisp.Compiler.eval_string(source, BeamLisp.Compiler.new_env(ns))
  end

  defp counter_mod(ns) do
    eval(ns, """
    (ns #{ns})
    (defserver counter
      (init [arg] (ok arg))
      (handle-call :inc [_from state] (reply (inc state) (inc state)))
      (handle-call :get [_from state] (reply state state))
      (handle-cast :reset [_state] (noreply 0)))
    counter
    """)
  end

  test "the generated module declares the :gen_server behaviour" do
    mod = counter_mod("w22decl")
    assert mod.module_info(:attributes)[:behaviour] == [:gen_server]
  end

  test "raw :gen_server call and cast work against it" do
    mod = counter_mod("w22raw")
    {:ok, pid} = :gen_server.start_link(mod, 5, [])

    assert :gen_server.call(pid, :inc) == 6
    assert :gen_server.call(pid, :get) == 6
    assert :gen_server.cast(pid, :reset) == :ok
    # A cast is asynchronous; the following call is the synchronisation
    # point, so no sleep is needed to observe its effect.
    assert :gen_server.call(pid, :get) == 0
  end

  test ":sys.get_state sees the server's state" do
    # `:sys` is the OTP debugging interface. It works only on a process
    # that genuinely implements the behaviour, so this is the sharpest
    # single test that the module is not a lookalike.
    mod = counter_mod("w22sys")
    {:ok, pid} = :gen_server.start_link(mod, 41, [])

    assert :sys.get_state(pid) == 41
    assert :gen_server.call(pid, :inc) == 42
    assert :sys.get_state(pid) == 42
  end

  test "a real Supervisor adopts it as a child" do
    mod = counter_mod("w22sup")
    children = [%{id: :counter, start: {:gen_server, :start_link, [mod, 0, []]}}]
    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

    assert %{active: 1, workers: 1, specs: 1} = Supervisor.count_children(sup)
    assert [{:counter, pid, :worker, _}] = Supervisor.which_children(sup)
    assert is_pid(pid)

    Supervisor.stop(sup)
  end

  test "a beam-lisp vector survives as server state" do
    # State crosses the callback boundary twice per call. A %Vector{} is a
    # struct, and a struct is a map on the BEAM — the recurring hazard in
    # this codebase — so it is exactly the value most likely to be
    # silently mangled into something else on the way through.
    mod =
      eval("w22vec", """
      (ns w22vec)
      (defserver holder
        (init [arg] (ok arg))
        (handle-call :push [_from state] (reply (conj state 9) (conj state 9)))
        (handle-call :get [_from state] (reply state state)))
      holder
      """)

    {:ok, pid} = :gen_server.start_link(mod, BeamLisp.Vector.new([1, 2]), [])

    assert %BeamLisp.Vector{} = :gen_server.call(pid, :get)
    pushed = :gen_server.call(pid, :push)
    assert %BeamLisp.Vector{} = pushed
    assert BeamLisp.RT.count(pushed) == 3
  end

  test "the client fns reach the server without raw interop" do
    # A server you can only talk to through :gen_server interop defeats
    # the point of having the form at all.
    assert eval("w22client", """
           (ns w22client)
           (defserver c
             (init [arg] (ok arg))
             (handle-call :inc [_from state] (reply (inc state) (inc state)))
             (handle-cast :reset [_state] (noreply 0)))
           (def p (server-start-link c 10))
           (server-call p :inc)
           (server-cast p :reset)
           (server-call p :inc)
           """) == 1
  end

  test "init can refuse to start" do
    mod =
      eval("w22stop", """
      (ns w22stop)
      (defserver refuses
        (init [_arg] (stop :nope))
        (handle-call :x [_from state] (reply state state)))
      refuses
      """)

    Process.flag(:trap_exit, true)
    assert {:error, :nope} = :gen_server.start_link(mod, nil, [])
  end
end
