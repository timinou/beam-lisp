defmodule BeamLisp.DocumentPolicyTest do
  use ExUnit.Case, async: false

  test "non-trusted policies refuse live and silent cells without writing" do
    BeamLisp.init()
    BeamLisp.Loader.ensure_loaded("bl.doc")
    root = Path.join(System.tmp_dir!(), "bl-doc-policy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    marker = Path.join(root, "executed")
    path = Path.join(root, "change.bl.org")
    source = "#+begin_src beam-lisp :id effect silent\n(File/write #{inspect(marker)} \"ran\")\n#+end_src\n"
    File.write!(path, source)
    runner = BeamLisp.Env.fetch!("bl.doc", "run-and-write!")
    for policy <- [:read_only, :changes_only, :unknown] do
      assert_raise BeamLisp.ExInfo, ~r/denied by policy/, fn ->
        BeamLisp.RT.invoke(runner, [path, %{policy: policy}])
      end
      refute File.exists?(marker)
      assert File.read!(path) == source
    end
    BeamLisp.RT.invoke(runner, [path, %{policy: :trusted}])
    assert File.read!(marker) == "ran"
  end
end
