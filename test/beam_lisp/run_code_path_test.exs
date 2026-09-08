defmodule BeamLisp.RunCodePathTest do
  use ExUnit.Case, async: false

  # `mix beam_lisp.run --code-path DIR` / `BEAM_LISP_CODE_PATH` must put a
  # directory of AOT beams where the loader's AOT-first branch can see it.
  # `ERL_AFLAGS="-pa DIR"` does not: Mix prunes the code path after loading
  # the project, so the beams vanished and every namespace compiled from
  # source — an application's 30s load with a "working" AOT build. This locks
  # in the flag and the env var, and that the pruned `-pa` is indeed gone
  # (so nobody reinstates it as the documented way).

  @tmp Path.join(System.tmp_dir!(), "beam_lisp_run_code_path")
  @src Path.join(@tmp, "src")
  @out Path.join(@tmp, "out")
  @ns "rcp.fixture"
  @mod BeamLisp.Ns.Rcp.Fixture

  setup do
    # A previous case (this module or another) may have left @out on the
    # code path; every case starts from "not on the path".
    Code.delete_path(@out)
    System.delete_env("BEAM_LISP_CODE_PATH")
    File.rm_rf!(@tmp)
    File.mkdir_p!(Path.join(@src, "rcp"))
    File.write!(Path.join(@src, "rcp/fixture.bl"), "(ns rcp.fixture)\n(defn answer [] 42)\n")
    Mix.Tasks.Compile.BeamLisp.clean(@out)
    assert {:ok, _} = Mix.Tasks.Compile.BeamLisp.run(["--source-dir", @src, "--out", @out])
    assert File.exists?(Path.join(@out, Atom.to_string(@mod) <> ".beam"))

    on_exit(fn ->
      Code.delete_path(@out)
      :code.purge(@mod)
      :code.delete(@mod)
      System.delete_env("BEAM_LISP_CODE_PATH")
      File.rm_rf!(@tmp)
    end)

    :ok
  end

  defp entry do
    path = Path.join(@tmp, "main.bl")
    # The entry's own dir is on the SOURCE search path, so the namespace loads
    # either way; what this checks is whether the beam directory is on the
    # VM's code path — the precondition for the AOT-first branch.
    File.write!(path, "(ns main)\n(println :on-path (some (fn [p] (= (unicode/characters_to_binary p) \"#{@out}\")) (code/get_path)))\n")
    path
  end

  # Straight through the loader, not the Mix task: the task's failure path is
  # `exit({:shutdown, 1})` after printing to stderr, which a test cannot read.
  # The code-path plumbing under test is `Mix.Tasks.BeamLisp.Run.code_paths/1`
  # applied exactly as `run/1` does.
  defp run(argv) do
    {opts, [path]} = OptionParser.parse!(argv, strict: [path: :keep, code_path: :keep])
    for dir <- Mix.Tasks.BeamLisp.Run.code_paths(opts), do: Code.prepend_path(Path.expand(dir))
    ExUnit.CaptureIO.capture_io(fn -> BeamLisp.run_file(path) end)
  end

  test "--code-path makes the AOT beam visible to the VM" do
    out = run(["--code-path", @out, entry()])
    assert out =~ ":on-path true", out
  end

  test "BEAM_LISP_CODE_PATH does the same from the environment" do
    System.put_env("BEAM_LISP_CODE_PATH", @out)
    out = run([entry()])
    assert out =~ ":on-path true", out
  end

  test "without either, the beam is not on the path (the pruned -pa is not a fallback)" do
    Code.delete_path(@out)
    out = run([entry()])
    assert out =~ ":on-path nil", out
  end
end
