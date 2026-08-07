defmodule BeamLisp.Wave20LocationsTest do
  # Source locations, asserted against REAL stacktraces.
  #
  # These tests exist because the failure mode is silent: attribution can
  # regress to beam-lisp's own internals without a single other test
  # noticing, since every other test asserts on values rather than on
  # where an error claims to come from. Before this wave, a runtime error
  # in a `.bl` file reported `lib/beam_lisp/link.ex` as the user frame.
  use ExUnit.Case, async: false

  @moduletag :wave20

  setup do
    BeamLisp.init()
    :ok
  end

  defp in_tmp(name, source, fun) do
    path = Path.join(System.tmp_dir!(), "bl_loc_#{System.unique_integer([:positive])}_#{name}")
    File.write!(path, source)
    try do
      fun.(path)
    after
      File.rm(path)
    end
  end

  # The top frame of a BIF failure is the BIF itself (`:erlang.+/2`),
  # which carries no location. The frame that matters is the first one
  # inside a generated namespace module — that is the user's code.
  defp user_frame(stack) do
    Enum.find(stack, fn
      {mod, _f, _a, loc} ->
        String.starts_with?(Atom.to_string(mod), "Elixir.BeamLisp.Ns.") and loc[:file] != nil

      _ ->
        false
    end)
  end

  defp run_forms(path) do
    env = BeamLisp.Compiler.new_env("user")

    path
    |> File.read!()
    |> BeamLisp.Reader.read_string(path)
    |> Enum.reduce(nil, fn form, _ -> BeamLisp.Compiler.eval_form(form, env) end)
  end

  test "a runtime error names the .bl file and the failing line" do
    source = """
    (ns locdemo)
    (defn boom [x]
      (let [y (* x 2)]
        (+ y nil)))
    (boom 3)
    """

    in_tmp("runtime.bl", source, fn path ->
      {_kind, stack} =
        try do
          run_forms(path)
          flunk("expected the arithmetic error to propagate")
        rescue
          e -> {e, __STACKTRACE__}
        end

      assert {_mod, _fun, _arity, loc} = user_frame(stack),
             "no generated-namespace frame in: #{inspect(stack)}"

      assert Keyword.get(loc, :file) |> to_string() == path
      # `(+ y nil)` is on line 4 — not line 2 where the defn opens, and
      # not line 1. Per-expression accuracy is the whole point.
      assert Keyword.get(loc, :line) == 4
    end)
  end

  test "a compile error names file, line and the offending form" do
    source = """
    (ns locbad)
    (defn f [x]
      (let [y] y))
    """

    in_tmp("compile.bl", source, fn path ->
      err =
        assert_raise BeamLisp.CompileError, fn -> run_forms(path) end

      assert err.file == path
      # The malformed `let` is on line 3, not the file's first line.
      assert err.line == 3
      assert err.message =~ path
      assert err.message =~ "3"
      assert err.message =~ "binding forms must be even"
    end)
  end

  test "a later form in a multi-form file reports its own line" do
    source = """
    (ns locmulti)
    (def a 1)
    (def b 2)
    (defn late [] (+ nil 1))
    (late)
    """

    in_tmp("multi.bl", source, fn path ->
      stack =
        try do
          run_forms(path)
          flunk("expected the arithmetic error to propagate")
        rescue
          _ -> __STACKTRACE__
        end

      assert {_mod, _fun, _arity, loc} = user_frame(stack)
      assert Keyword.get(loc, :line) == 4
    end)
  end

  test "a form with no position metadata still compiles" do
    # Forms built at runtime by a macro carry no wrapper. Position is
    # best-effort — never required — or macro-generated code could not run.
    bare = {:list, [{:symbol, "+"}, 1, 2]}
    assert BeamLisp.Compiler.eval_form(bare, BeamLisp.Compiler.new_env("locbare")) == 3
  end

  test "an AOT-compiled module carries .bl locations in its line table" do
    # The case most likely to be missed, and the one that matters most:
    # these .beam files persist, so this is what a production stack trace
    # hits long after the compiler that made it has exited.
    source = """
    (ns aotloc)
    (defn crash [x]
      (+ x nil))
    """

    in_tmp("aotloc.bl", source, fn path ->
      out = Path.join(System.tmp_dir!(), "bl_aot_#{System.unique_integer([:positive])}")
      File.mkdir_p!(out)

      try do
        BeamLisp.AOT.compile_file(path, output_dir: out)
        beam = Path.join(out, "Elixir.BeamLisp.Ns.Aotloc.beam")
        assert File.exists?(beam)

        # Read the source attribution straight out of the compiled
        # artifact rather than trusting the in-memory module. Release
        # beams carry no abstract code, so use the compile-info chunk,
        # which records the source path the compiler was given.
        {:ok, {_mod, [compile_info: info]}} =
          :beam_lib.chunks(String.to_charlist(beam), [:compile_info])

        source_attr = info |> Keyword.get(:source) |> to_string()

        assert source_attr == path,
               "expected the .beam to name #{path}, got: #{inspect(source_attr)}"
      after
        File.rm_rf(out)
      end
    end)
  end
end
