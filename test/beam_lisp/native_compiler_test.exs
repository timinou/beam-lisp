defmodule BeamLisp.NativeCompilerTest do
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "lazy_native_build_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "native/lazy_memo"))

    File.write!(
      Path.join(root, "native/lazy_memo/Cargo.toml"),
      "[package]\nname = \"lazy_memo\"\n"
    )

    old_path = System.get_env("PATH")
    System.put_env("PATH", "")

    on_exit(fn ->
      if old_path, do: System.put_env("PATH", old_path), else: System.delete_env("PATH")
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "missing required runtime fails before AOT when cargo is absent", %{root: root} do
    File.cd!(root, fn ->
      assert_raise Mix.Error, ~r/LazySeq requires the lazy_memo native runtime/, fn ->
        Mix.Tasks.Compile.BeamLispNative.run([])
      end
    end)
  end

  test "current installed runtime can be used without cargo", %{root: root} do
    File.cd!(root, fn ->
      File.mkdir_p!("priv/native")
      File.write!("priv/native/lazy_memo.so", "fixture artifact; this test does not load it")
      File.touch!("native/lazy_memo/Cargo.toml", {{2000, 1, 1}, {0, 0, 0}})
      assert {:ok, []} = Mix.Tasks.Compile.BeamLispNative.run([])
    end)
  end

  test "a changed lockfile requires rebuilding the runtime", %{root: root} do
    File.cd!(root, fn ->
      File.mkdir_p!("priv/native")
      File.write!("priv/native/lazy_memo.so", "fixture artifact")
      File.touch!("priv/native/lazy_memo.so", {{2001, 1, 1}, {0, 0, 0}})
      File.touch!("native/lazy_memo/Cargo.toml", {{2000, 1, 1}, {0, 0, 0}})
      File.write!("native/lazy_memo/Cargo.lock", "changed dependency lock")

      assert_raise Mix.Error, ~r/Install cargo/, fn ->
        Mix.Tasks.Compile.BeamLispNative.run([])
      end
    end)
  end
end
