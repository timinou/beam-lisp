defmodule BeamLisp.Spell.CodeRungTest do
  @moduledoc """
  The fence rung (W4): `defn`/`def` source compiles AND loads in a bounded,
  unlinked process before the verdict — a syntax error, a crash, or a
  wedging initializer is refused there and the loop walks away.
  """
  use ExUnit.Case, async: false

  alias BeamLisp.Spell.Loop
  alias BeamLisp.Spell.Persist

  setup do
    dir = Path.join(System.tmp_dir!(), "spell-code-#{System.unique_integer([:positive])}")
    Application.put_env(:beam_lisp, :spell_state_dir, dir)

    on_exit(fn ->
      Application.delete_env(:beam_lisp, :spell_state_dir)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  test "an accepted defn is live in the image immediately", %{dir: _dir} do
    {:ok, pid} = Loop.start_link(name: nil, publish: false, persist: true)

    assert %{status: :ok, kind: "code", name: "w4-double"} =
             Loop.run(pid, "(defn w4-double [x] (+ x x))", "a helper")

    # The var registry is the image's: the fenced process's successful eval
    # IS the commit. Fetchable right now, before any restart.
    assert {:ok, _} = BeamLisp.Env.fetch("spell.vars", "w4-double")
    GenServer.stop(pid)
  end

  test "a defn that does not COMPILE is refused at the fence rung", %{dir: _dir} do
    {:ok, pid} = Loop.start_link(name: nil, publish: false, persist: true)

    # An unresolved CALL is not a compile error in this image (vars link at
    # call time — that is what a live image means). A body that is malformed
    # for the COMPILER is: `let` with an odd binding vector fails to emit.
    assert %{status: :rejected, rung: :fence} =
             Loop.run(pid, "(defn w4-broken [x] (let [x] x))", "broken")

    # and nothing journaled — only accepted source is remembered
    assert Persist.vars() == []
    GenServer.stop(pid)
  end

  test "a def whose initializer WEDGES is refused after the deadline", %{dir: _dir} do
    {:ok, pid} = Loop.start_link(name: nil, publish: false, persist: true)

    assert %{status: :rejected, rung: :fence, reason: reason} =
             Loop.run(pid, "(def w4-wedge (loop [] (recur)))", "wedges")

    assert reason =~ "timeout"
    # the loop itself is alive and answering — the fence, not the loop, paid
    assert %{machine: _} = Loop.state(pid)
    GenServer.stop(pid)
  end

  test "defmacro and defserver never reach the fence — refused at the schema rung", %{dir: _dir} do
    {:ok, pid} = Loop.start_link(name: nil, publish: false, persist: true)

    assert %{status: :rejected, rung: :schema, reason: reason} =
             Loop.run(pid, "(defmacro sneaky [x] x)", "macro attempt")

    assert reason =~ "defmacro"

    assert %{status: :rejected, rung: :schema} =
             Loop.run(pid, "(defserver s (handlers))", "server attempt")

    GenServer.stop(pid)
  end

  test "a journaled var is replayed at boot, BEFORE the definitions", %{dir: dir} do
    {:ok, first} = Loop.start_link(name: nil, publish: false, persist: true)
    assert %{status: :ok} = Loop.run(first, "(def w4-meaning 42)", "a value")
    GenServer.stop(first)

    {:ok, second} = Loop.start_link(name: nil, publish: false, persist: true)
    assert {:ok, _} = BeamLisp.Env.fetch("spell.vars", "w4-meaning")
    assert File.exists?(Path.join([dir, "vars", "spell.vars.bl"]))
    GenServer.stop(second)
  end

  test "a var journaled into illegibility does not strand the boot", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "vars"))
    File.write!(Path.join([dir, "vars", "spell.vars.bl"]), "(defn torn [x]\n")

    {:ok, pid} = Loop.start_link(name: nil, publish: false, persist: true)
    assert %{machine: _} = Loop.state(pid)
    assert File.ls!(Path.join(dir, "vars")) |> Enum.any?(&String.contains?(&1, "corrupt"))
    GenServer.stop(pid)
  end
end
