defmodule BeamLisp.Wave23LoaderTest do
  use ExUnit.Case, async: false

  # Loader namespace-honesty: a require resolves to the file whose
  # declared `(ns …)` owns the requested name, not to the first
  # same-named file on the path. These tests exercise that resolution
  # with real `.bl` files in tmp dirs. Unique namespaces per test keep
  # them independent of the shared BEAM's loaded set.

  alias BeamLisp.{Env, Loader}

  setup do
    BeamLisp.init()
    Env.in_ns("user")
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  defp tmpdir(label) do
    path = Path.join(System.tmp_dir!(), "bl_w23_#{label}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  # Push `dirs` onto the load path so they are searched in the given
  # order (the first is highest priority, mirroring how run_file puts the
  # running file's directory at the front), run `fun`, and pop them all.
  defp with_load_dirs(dirs, fun) do
    Enum.reduce(dirs, fun, fn dir, f -> fn -> Loader.with_load_path(dir, f) end end).()
  end

  test "a same-basename file with a different ns does not hijack the require" do
    dir = tmpdir("hijack")
    wrong = Path.join(dir, "wrong")
    real = Path.join(dir, "real")
    File.mkdir_p!(wrong)
    File.mkdir_p!(real)

    # The shadowing file (higher priority) shares the name but declares a
    # different ns — exactly the example-vs-library collision. It must be
    # skipped, not loaded.
    File.write!(Path.join(wrong, "w23lib.bl"), """
    (ns w23lib.other)
    (def hijack :should-not-load)
    """)

    File.write!(Path.join(real, "w23lib.bl"), """
    (ns w23lib)
    (def from-dir :real)
    """)

    with_load_dirs([wrong, real], fn ->
      eval("(ns w23.hijackapp (:require [w23lib :as lib]))")
      assert eval("lib/from-dir") == :real
    end)

    # The hijacking ns was never loaded; the real one was.
    refute Env.loaded_ns?("w23lib.other")
    assert Env.loaded_ns?("w23lib")
    File.rm_rf!(dir)
  end

  test "a genuine same-ns project file still shadows a lower-priority one" do
    dir = tmpdir("override")
    project = Path.join(dir, "project")
    lower = Path.join(dir, "lower")
    File.mkdir_p!(project)
    File.mkdir_p!(lower)

    # Both files declare the requested ns; the higher-priority project
    # file owns it and wins, exactly as a user's optics.bl would shadow
    # priv/optics.bl.
    File.write!(Path.join(project, "w23ovr.bl"), """
    (ns w23ovr)
    (def origin :project)
    """)

    File.write!(Path.join(lower, "w23ovr.bl"), """
    (ns w23ovr)
    (def origin :lower)
    """)

    with_load_dirs([project, lower], fn ->
      eval("(ns w23.ovrapp (:require [w23ovr]))")
      assert eval("w23ovr/origin") == :project
    end)

    File.rm_rf!(dir)
  end

  test "a priv/ library loads when nothing on the load path shadows it" do
    # An empty high-priority dir leaves the real priv/rewrite.bl as the
    # only provider.
    dir = tmpdir("priv")
    with_load_dirs([dir], fn ->
      eval("(ns w23.privapp (:require [rewrite]))")
      assert eval("(rewrite/apply-rules (list) '(a b))") == [{:symbol, "a"}, {:symbol, "b"}]
      assert Env.loaded_ns?("rewrite")
    end)
    File.rm_rf!(dir)
  end

  test "a same-named file with a different ns is skipped even against a real priv lib" do
    dir = tmpdir("privskip")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "optics.bl"), """
    (ns optics.different)
    (def decoy :nope)
    """)

    with_load_dirs([dir], fn ->
      eval("(ns w23.privskipapp (:require [optics]))")
      # The real priv/optics.bl won the require past the decoy.
      assert eval("(optics/view (optics/in :a) {:a 42})") == 42
      refute Env.loaded_ns?("optics.different")
    end)
    File.rm_rf!(dir)
  end

  test "a missing ns with a same-named wrong-ns file names both namespaces" do
    dir = tmpdir("err")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "w23err.bl"), """
    (ns w23err.other)
    (def whatever 1)
    """)

    with_load_dirs([dir], fn ->
      error = assert_raise RuntimeError, fn ->
        eval("(ns w23.errapp (:require [w23err]))")
      end

      assert error.message =~ "namespace w23err"
      assert error.message =~ "w23err.bl"
      assert error.message =~ "declares (ns w23err.other), not w23err"
    end)
    File.rm_rf!(dir)
  end

  test "a file with no (ns …) form is reported, not loaded" do
    dir = tmpdir("nons")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "w23none.bl"), """
    (def orphan 1)
    """)

    with_load_dirs([dir], fn ->
      error = assert_raise RuntimeError, fn ->
        eval("(ns w23.noneapp (:require [w23none]))")
      end

      assert error.message =~ "namespace w23none"
      assert error.message =~ "w23none.bl"
      assert error.message =~ "declares no (ns …) form"
      refute Env.loaded_ns?("w23none")
    end)
    File.rm_rf!(dir)
  end

  test "dotted namespaces still resolve to nested directories" do
    dir = tmpdir("dotted")
    nested = Path.join(dir, "a/b")
    File.mkdir_p!(nested)

    File.write!(Path.join(nested, "thing.bl"), """
    (ns a.b.thing)
    (def nested :yes)
    """)

    with_load_dirs([dir], fn ->
      eval("(ns w23.dottedapp (:require [a.b.thing :as t]))")
      assert eval("t/nested") == :yes
      assert Env.loaded_ns?("a.b.thing")
    end)
    File.rm_rf!(dir)
  end
end
