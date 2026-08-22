defmodule BeamLisp.Wave9AotTest do
  use ExUnit.Case, async: false

  # AOT: `.bl` sources become real BEAM modules on the code path, so a
  # fresh VM loads and runs them with no runtime compilation. The key
  # assertion is the subprocess in `fresh VM ...` — that elixir process
  # only does `Code.ensure_loaded` + `__bl_init__/0`, never the compiler.

  alias BeamLisp.Env

  @fixture_dir "test/fixtures/aot"
  @compile_path Mix.Project.compile_path()

  setup_all do
    BeamLisp.init()

    # Start from a clean slate, then compile the fixture set once for all
    # tests in this module.
    Mix.Tasks.Compile.BeamLisp.clean()
    assert {:ok, []} = Mix.Tasks.Compile.BeamLisp.run(["--source-dir", @fixture_dir])
    :ok
  end

  defp beam_path(mod), do: Path.join(@compile_path, Atom.to_string(mod) <> ".beam")

  test "emits one .beam module per namespace" do
    for mod <- [BeamLisp.Ns.Math, BeamLisp.Ns.Hello, BeamLisp.Ns.Greeter] do
      assert File.exists?(beam_path(mod)), "missing #{beam_path(mod)}"
    end
  end

  test "compiled modules answer correctly in-process" do
    math = BeamLisp.Ns.Math
    hello = BeamLisp.Ns.Hello
    greeter = BeamLisp.Ns.Greeter

    assert math.square(6) == 36
    assert math.add(7, 8) == 15
    # value def read from a defn body, re-interned by __bl_init__/0
    assert math."answer-mul"(3) == 126
    assert math.describe() == "answer=42"
    # macro defined and used in the same file
    assert math.double(21) == 42

    # Three clauses of ONE arity, chosen by their `:when` guards. This is
    # the AOT-specific risk: the generated namespace module holds shims,
    # and a shim that dropped its guard would forward every call to the
    # first clause — `sign(-1)` would answer `:positive`.
    assert math.sign(5) == :positive
    assert math.sign(-5) == :negative
    assert math.sign(0) == :zero
    assert hello.greet("world") == "hi, world!"
    assert hello.shout("loud") == "LOUD"
    # cross-ns :require + :refer + :as all resolve
    assert greeter.report(4) == "hi, aot! | 16 | LOUD"

    # fn *values* are interned as captures, so `map f` / RT.invoke work
    {:ok, sumv} = Env.fetch("math", "sum")
    assert BeamLisp.RT.invoke(sumv, [1, 2, 3, 4]) == 10
    {:ok, addv} = Env.fetch("math", "add")
    assert BeamLisp.RT.invoke(addv, [9, 10]) == 19
  end

  test "fresh VM loads the beams with no runtime compilation" do
    script = """
    Application.load(:beam_lisp)
    {:ok, _} = BeamLisp.Env.start_link([])
    BeamLisp.init()
    for ns <- ["math", "hello", "greeter"], do: BeamLisp.AOT.ensure_loaded(ns)
    # must be loaded from a .beam on the path (not Module.create'd)
    IO.puts("loaded_from=" <> to_string(:code.which(BeamLisp.Ns.Math)))
    IO.puts("has_bl_init=" <> to_string(function_exported?(BeamLisp.Ns.Math, :__bl_init__, 0)))
    IO.puts("square=" <> to_string(BeamLisp.Ns.Math.square(9)))
    IO.puts("answer_mul=" <> to_string(BeamLisp.Ns.Math."answer-mul"(3)))
    IO.puts("double=" <> to_string(BeamLisp.Ns.Math.double(21)))
    IO.puts("greet=" <> BeamLisp.Ns.Hello.greet("world"))
    IO.puts("report=" <> BeamLisp.Ns.Greeter.report(3))
    """

    {out, 0} =
      System.cmd("elixir", ["-pa", @compile_path, "-e", script], stderr_to_stdout: true)

    # Loaded from disk, carries the AOT init hook, answers correctly.
    assert out =~ "loaded_from=" <> @compile_path
    assert out =~ "has_bl_init=true"
    assert out =~ "square=81"
    assert out =~ "answer_mul=126"
    assert out =~ "double=42"
    assert out =~ "greet=hi, world!"
    assert out =~ "report=hi, aot! | 9 | LOUD"
  end

  test "second run recompiles nothing" do
    before = for mod <- [BeamLisp.Ns.Math, BeamLisp.Ns.Hello], do: {mod, beam_mtime(mod)}

    assert {:noop, []} = Mix.Tasks.Compile.BeamLisp.run(["--source-dir", @fixture_dir])

    for {mod, mtime} <- before do
      assert beam_mtime(mod) == mtime
    end
  end

  test "clean removes generated modules and the manifest" do
    assert File.exists?(beam_path(BeamLisp.Ns.Math))

    Mix.Tasks.Compile.BeamLisp.clean()

    refute File.exists?(beam_path(BeamLisp.Ns.Math))
    refute File.exists?(Path.join(Mix.Project.manifest_path(), "compile.beam_lisp"))

    # Recompile so the rest of the suite still sees them.
    assert {:ok, []} = Mix.Tasks.Compile.BeamLisp.run(["--source-dir", @fixture_dir])
  end

  defp beam_mtime(mod), do: File.stat!(beam_path(mod)).mtime
end
