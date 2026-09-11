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

  # The macOS leg of the release matrix can only be BUILT on macOS, so the two
  # halves of the cross-platform naming — cargo's `.dylib` output, and the `.so`
  # the BEAM loads — are asserted here, where a Linux host can still reach them.
  # Testing only the Linux name would leave the arm that broke untested: a
  # successful macOS build reported as a missing crate.
  describe "cross-platform artefact naming" do
    test "finds cargo's darwin cdylib name" do
      dir = Path.join(System.tmp_dir!(), "dylib_probe_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert Mix.Tasks.Compile.BeamLispNative.built_path(dir, "lazy_memo") == nil

      File.write!(Path.join(dir, "liblazy_memo.dylib"), "fixture; never loaded")

      assert Mix.Tasks.Compile.BeamLispNative.built_path(dir, "lazy_memo") ==
               Path.join(dir, "liblazy_memo.dylib")

      # linux's name wins when both are present (they never are in practice)
      File.write!(Path.join(dir, "liblazy_memo.so"), "fixture")

      assert Mix.Tasks.Compile.BeamLispNative.built_path(dir, "lazy_memo") ==
               Path.join(dir, "liblazy_memo.so")
    end

    test "installs under the extension the BEAM appends, not cargo's name" do
      # Every unix — darwin included — takes the `.so` arm. This is the line
      # that makes a macOS `.dylib` loadable.
      if match?({:win32, _}, :os.type()) do
        assert Mix.Tasks.Compile.BeamLispNative.nif_ext() == ".dll"
      else
        assert Mix.Tasks.Compile.BeamLispNative.nif_ext() == ".so"
      end

      # cargo's `lib` prefix is dropped: `BeamLisp.Native` asks for
      # `priv/native/<crate>`.
      assert Mix.Tasks.Compile.BeamLispNative.installed_path("lazy_memo") ==
               "priv/native/lazy_memo#{Mix.Tasks.Compile.BeamLispNative.nif_ext()}"
    end
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
