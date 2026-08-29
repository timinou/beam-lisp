defmodule BeamLisp.CapsTest do
  @moduledoc """
  The capability gate's deny-corpus: every bl→host escape spelling,
  attempted from a capability-restricted env, must FAIL CLOSED.

  Same discipline as the Biscuit conformance corpus: the point is not that
  these tests pass today but that they keep failing-closed forever — a
  regression here is a privilege-escalation hole, not a behavior change.

  The interop surface (audited, 4 paths):
    1. static remote call        `(File/read "x")`        → compile error
    2. remote fn as value        `String/upcase`          → remote_fun raise
    3. dynamic invoke of handle  forged `{:"$remote",…}`  → invoke raise
    4. defnative                 NIF installation         → compile error
  """
  use ExUnit.Case, async: false

  alias BeamLisp.Env

  setup do
    BeamLisp.init()
    :ok
  end

  defp eval_in(caps, source) do
    Env.isolated(Env.fork(:global, caps: caps), fn ->
      BeamLisp.eval(source)
    end)
  end

  # -- path 1: static remote call -------------------------------------

  test "static Elixir interop denied at COMPILE time (no bytecode exists)" do
    assert_raise BeamLisp.CompileError, ~r/module File is not granted/, fn ->
      eval_in([String], ~s|(ns t.capped) (File/read "/etc/passwd")|)
    end
  end

  test "static Erlang interop denied (lowercase prefix path)" do
    assert_raise BeamLisp.CompileError, ~r/module :os is not granted/, fn ->
      eval_in([], ~s|(ns t.capped) (os/cmd "id")|)
    end
  end

  test "granted modules compile and run" do
    assert eval_in([String], ~s|(ns t.ok) (String/upcase "hi")|) == "HI"
  end

  # -- path 2: remote fn as a value -----------------------------------

  test "remote fn handle cannot be FORGED in a capped env" do
    assert_raise BeamLisp.CompileError, ~r/module System is not granted/, fn ->
      eval_in([String], ~s|(ns t.capped) (map System/getenv ["HOME"])|)
    end
  end

  # -- path 3: dynamic invoke of a handle smuggled in from outside -----

  test "a $remote handle created at :global cannot fire inside a capped env" do
    handle = BeamLisp.RT.remote_fun(String, :upcase)

    assert_raise BeamLisp.CompileError, ~r/module String is not granted/, fn ->
      Env.isolated(Env.fork(:global, caps: []), fn ->
        BeamLisp.RT.invoke(handle, ["hi"])
      end)
    end
  end

  # -- path 4: defnative -----------------------------------------------

  test "defnative denied in a capped env (NIFs are substrate)" do
    assert_raise BeamLisp.CompileError, ~r/defnative is not available/, fn ->
      eval_in([String], ~s|(ns t.capped) (defnative "evil" (pwn 1))|)
    end
  end

  # -- attenuation monotonicity (the Biscuit invariant) ----------------

  test "fork caps are parent ∩ spec — narrowing only, never widening" do
    parent = Env.fork(:global, caps: [File, String])

    # child asks for MORE than the parent holds → System absent
    child = Env.fork(parent, caps: [File, String, System])
    assert Env.caps_of(child) == MapSet.new([File, String])

    # child asks for nothing → inherits parent's set exactly
    child2 = Env.fork(parent)
    assert Env.caps_of(child2) == MapSet.new([File, String])

    # grandchild narrows further
    grandchild = Env.fork(child, caps: [String])
    assert Env.caps_of(grandchild) == MapSet.new([String])

    # ...and cannot regain File
    assert_raise BeamLisp.CompileError, ~r/module File is not granted/, fn ->
      Env.isolated(grandchild, fn ->
        BeamLisp.eval(~s|(ns t.deep) (File/read "/etc/passwd")|)
      end)
    end
  end

  test "caps travel with capture/bind (spawn propagation)" do
    env = Env.fork(:global, caps: [String])

    Env.with_env(env, fn ->
      token = Env.capture()

      task =
        Task.async(fn ->
          Env.bind(token)
          Env.caps()
        end)

      assert Task.await(task) == MapSet.new([String])
    end)
  end

  test "a destroyed env's stale binding fails CLOSED (no caps, not :all)" do
    env = Env.fork(:global, caps: [String])
    token = Env.with_env(env, fn -> Env.capture() end)
    Env.destroy(env)

    assert Env.caps_of(env) == MapSet.new()

    task =
      Task.async(fn ->
        Env.bind(token)
        Env.caps()
      end)

    assert Task.await(task) == MapSet.new()
  end

  test ":global and unbound processes keep :all (zero migration cost)" do
    assert Env.caps() == :all
    assert Env.caps_of(:global) == :all
    assert Env.caps_allowed?(System)
    assert eval_in(:all, ~s|(ns t.global) (String/downcase "HI")|) == "hi"
  end

  test "ungranted pure-bl code is unaffected (the gate only mediates host calls)" do
    assert eval_in([], ~s|(ns t.pure) (defn dbl [x] (* x 2)) (dbl 21)|) == 42
  end

  # ══ doctrine boundary ═══════════════════════════════════════════════
  #
  # The gate governs NEW compilation and dynamic forging inside a capped
  # env. It does NOT re-mediate code that was already compiled at :global
  # — by doctrine the base image is part of the parent's authority
  # (setuid-helper semantics, PLAN-047 "Known limits"). These two tests
  # PIN that boundary: they document exactly where authority leaks by
  # design, and assert the mitigation. A change in EITHER direction —
  # the escape starting to deny, or the mitigation starting to leak — is
  # a semantic shift someone must notice on purpose.

  defp tmp_secret! do
    path = Path.join(System.tmp_dir!(), "caps_secret_#{System.unique_integer([:positive])}")
    File.write!(path, "TOP-SECRET")
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "DOCTRINE: a closure compiled at :global carries its authority past the gate" do
    secret = tmp_secret!()
    # Built where File IS granted — the static (File/read …) baked a DIRECT
    # apply, not a gated $remote handle. Nothing re-checks it later.
    leak = BeamLisp.eval(~s|(ns atk.forge) (fn [p] (File/read p))|)

    # Invoked inside an env that grants ONLY String, it STILL reads the
    # file. This is the setuid leak, stated out loud: a :global-compiled
    # wrapper reachable from a sandbox lends the sandbox its authority.
    assert {:ok, "TOP-SECRET"} =
             Env.isolated(Env.fork(:global, caps: [String]), fn ->
               BeamLisp.RT.invoke(leak, [secret])
             end)

    # The mitigation is compile-time: writing that SAME call *inside* the
    # capped env never produces bytecode. The rule for operators follows
    # directly — anything a sandbox must not DO must not be reachable
    # through a :global-loaded wrapper either.
    assert_raise BeamLisp.CompileError, ~r/module File is not granted/, fn ->
      eval_in([String], ~s|(ns atk.inline) (File/read "#{secret}")|)
    end
  end

  test "DOCTRINE: a confused deputy leaks unless it CONVEYS the caller's env" do
    secret = tmp_secret!()
    parent = self()

    # A naive deputy serves whoever asks, using its OWN :global authority.
    naive =
      spawn(fn ->
        receive do
          {:read, path, from} -> send(from, {:served, File.read!(path)})
        end
      end)

    naive_result =
      Env.isolated(Env.fork(:global, caps: [String]), fn ->
        send(naive, {:read, secret, self()})
        receive do
          msg -> msg
        after
          1000 -> :timeout
        end
      end)

    # The capped client could not read the file itself, yet the deputy did
    # it on their behalf — the classic confused-deputy exposure.
    assert {:served, "TOP-SECRET"} = naive_result

    # The fix: the deputy re-enters the CALLER's conveyed env before doing
    # the work, and reaches the resource through the gated interop path.
    # Now the caller's caps (String only) govern, and File is denied.
    fileread = BeamLisp.RT.remote_fun(File, :read)

    convey =
      spawn(fn ->
        receive do
          {:read, path, token, from} ->
            result =
              try do
                Env.bind(token)
                {:served, BeamLisp.RT.invoke(fileread, [path])}
              rescue
                e -> {:denied, e.__struct__}
              end

            send(from, result)
        end
      end)

    convey_result =
      Env.isolated(Env.fork(:global, caps: [String]), fn ->
        send(convey, {:read, secret, Env.capture(), self()})
        receive do
          msg -> msg
        after
          1000 -> :timeout
        end
      end)

    assert {:denied, BeamLisp.CompileError} = convey_result
    _ = parent
  end
end
