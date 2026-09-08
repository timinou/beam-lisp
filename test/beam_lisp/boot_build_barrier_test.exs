defmodule BeamLisp.BootBuildBarrierTest do
  use ExUnit.Case, async: false

  setup_all do
    BeamLisp.init()
    BeamLisp.Loader.ensure_loaded("build")
    :ok
  end

  defp call(name, args) do
    BeamLisp.RT.invoke(BeamLisp.Env.fetch!("build", name), args)
  end

  defp node(path, ns), do: %{path: path, ns: ns, hash: ns}

  test "boot nodes form a serial topological prefix and ordinary waves stay parallel" do
    boot_dir = BeamLisp.Tiers.boot_dir()
    core = node(Path.join(boot_dir, "core.bl"), "core")
    compiler = node(Path.join(boot_dir, "compiler.bl"), "compiler")
    a = node("priv/std/a.bl", "a")
    b = node("priv/std/b.bl", "b")

    partition =
      call("partition-plan", [
        %{
          order: [core, compiler, a, b],
          waves: [[core, a], [compiler, b]],
          deps: %{core.path => [], compiler.path => [core.path], a.path => [], b.path => [a.path]}
        }
      ])

    assert Enum.map(partition.boot, & &1.path) == [core.path, compiler.path]

    assert Enum.map(partition[:"ordinary-waves"], fn wave -> Enum.map(wave, & &1.path) end) == [
             [a.path],
             [b.path]
           ]

    assert Enum.to_list(partition.errors) == []
  end

  test "boot dependency on an ordinary source is rejected before scheduling" do
    boot = node(Path.join(BeamLisp.Tiers.boot_dir(), "compiler.bl"), "compiler")
    ordinary = node("priv/std/helper.bl", "helper")

    partition =
      call("partition-plan", [
        %{
          order: [ordinary, boot],
          waves: [[ordinary], [boot]],
          deps: %{boot.path => [ordinary.path], ordinary.path => []}
        }
      ])

    assert [error] = Enum.to_list(partition.errors)
    assert error =~ "boot source #{boot.path} requires ordinary source #{ordinary.path}"
  end

  test "boot errors close the ordinary-source execution gate" do
    # The barrier is BOOT-source errors only (1baaab4): an ordinary source
    # failing to compile is a report, not a reason to skip every later wave.
    boot = Path.join(BeamLisp.Tiers.boot_dir(), "compiler.bl")
    assert call("continue-after-boot?", [%{errors: [], "boot-paths": [boot]}])
    assert call("continue-after-boot?", [%{errors: ["priv/std/helper.bl: failed"], "boot-paths": [boot]}])
    refute call("continue-after-boot?", [%{errors: ["#{boot}: failed"], "boot-paths": [boot]}])
  end

  test "relative source paths and Mix priv symlinks identify the same boot tier" do
    assert BeamLisp.Tiers.boot_source?("priv/boot/core.bl")
    assert BeamLisp.Tiers.boot_source?(Path.join(BeamLisp.Tiers.boot_dir(), "core.bl"))
    refute BeamLisp.Tiers.boot_source?("priv/std/errors.bl")
  end

  test "staged build refresh decision is narrow" do
    refute Mix.Tasks.Compile.BeamLisp.refresh_staged_build?([])
    refute Mix.Tasks.Compile.BeamLisp.refresh_staged_build?(["compiler", "reader"])
    assert Mix.Tasks.Compile.BeamLisp.refresh_staged_build?(["compiler", "build"])
  end
end
