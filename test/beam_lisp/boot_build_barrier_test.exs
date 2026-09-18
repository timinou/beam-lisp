defmodule BeamLisp.BootBuildBarrierTest do
  use ExUnit.Case, async: false

  # The toolchain barrier: codegen (`priv/boot/`) and the build driver
  # (`priv/build/`) build SERIALLY, before the parallel ordinary waves, because
  # the compiler and the program scheduling it must both be sound before
  # anything else is compiled. A toolchain source requiring an ordinary source
  # is a structural error, rejected before any scheduling.

  setup_all do
    BeamLisp.init()
    BeamLisp.Loader.ensure_loaded("build")
    :ok
  end

  defp call(name, args), do: BeamLisp.RT.invoke(BeamLisp.Env.fetch!("build", name), args)

  defp node(path, ns), do: %{path: path, ns: ns, hash: ns}

  test "toolchain nodes form a serial topological prefix and ordinary waves stay parallel" do
    boot_dir = BeamLisp.Tiers.boot_dir()
    core = node(Path.join(boot_dir, "core.bl"), "core")
    compiler = node(Path.join(boot_dir, "compiler.bl"), "compiler")
    driver = node(Path.join(BeamLisp.Tiers.build_dir(), "build.bl"), "build")
    a = node("priv/std/a.bl", "a")
    b = node("priv/std/b.bl", "b")

    partition =
      call("partition-plan", [
        %{
          order: [core, compiler, driver, a, b],
          waves: [[core, a], [compiler, driver], [b]],
          deps: %{
            core.path => [],
            compiler.path => [core.path],
            driver.path => [],
            a.path => [],
            b.path => [a.path]
          }
        }
      ])

    # BOTH tiers are in the serial prefix: codegen AND the driver.
    assert Enum.map(partition.toolchain, & &1.path) == [core.path, compiler.path, driver.path]

    assert Enum.map(partition[:"ordinary-waves"], fn wave -> Enum.map(wave, & &1.path) end) == [
             [a.path],
             [b.path]
           ]

    assert Enum.to_list(partition.errors) == []
  end

  test "a toolchain dependency on an ordinary source is rejected before scheduling" do
    boot = node(Path.join(BeamLisp.Tiers.boot_dir(), "compiler.bl"), "compiler")
    driver = node(Path.join(BeamLisp.Tiers.build_dir(), "build.bl"), "build")
    ordinary = node("priv/std/helper.bl", "helper")

    partition =
      call("partition-plan", [
        %{
          order: [ordinary, boot, driver],
          waves: [[ordinary], [boot], [driver]],
          deps: %{boot.path => [ordinary.path], driver.path => [], ordinary.path => []}
        }
      ])

    assert [error] = Enum.to_list(partition.errors)
    assert error =~ "toolchain source #{boot.path} requires ordinary source #{ordinary.path}"
  end

  test "toolchain errors close the ordinary-source execution gate" do
    # The barrier is TOOLCHAIN-source errors only (1baaab4): an ordinary source
    # failing to compile is a report, not a reason to skip every later wave.
    boot = Path.join(BeamLisp.Tiers.boot_dir(), "compiler.bl")
    driver = Path.join(BeamLisp.Tiers.build_dir(), "build.bl")

    assert call("continue-after-toolchain?", [%{errors: [], "toolchain-paths": [boot, driver]}])

    assert call("continue-after-toolchain?", [
             %{errors: ["priv/std/helper.bl: failed"], "toolchain-paths": [boot, driver]}
           ])

    refute call("continue-after-toolchain?", [
             %{errors: ["#{boot}: failed"], "toolchain-paths": [boot]}
           ])

    refute call("continue-after-toolchain?", [
             %{errors: ["#{driver}: failed"], "toolchain-paths": [driver]}
           ])
  end

  test "the tier law: std/lib/compat may require the graph kernel, never the driver" do
    # The law of tiers.ex, enforced over SOURCE with the kernel itself: every
    # `.bl` under the program tiers is read by `SourceGraph.header` (the one
    # parser), and no `:require` may name a driver namespace. `source-graph`
    # is the kernel — std dev tooling (codebase, reload) requires it by
    # design (PLAN-125).
    driver = BeamLisp.Tiers.build_namespaces() -- BeamLisp.Tiers.build_kernel_namespaces()

    offenders =
      for tier <- ~w(std lib compat),
          path <- Path.wildcard(Path.join([BeamLisp.Tiers.priv_root(), tier, "**", "*.bl"])),
          {ns, requires} <- [BeamLisp.SourceGraph.header(File.read!(path))],
          bad = Enum.sort(Enum.filter(requires, &(&1 in driver))),
          bad != [] do
        {path, ns, bad}
      end

    assert offenders == []
  end

  test "each tier's sources are recognised, relative or absolute" do
    assert BeamLisp.Tiers.boot_source?("priv/boot/core.bl")
    assert BeamLisp.Tiers.boot_source?(Path.join(BeamLisp.Tiers.boot_dir(), "core.bl"))
    refute BeamLisp.Tiers.boot_source?("priv/build/build.bl")

    assert BeamLisp.Tiers.build_source?("priv/build/build.bl")
    refute BeamLisp.Tiers.build_source?("priv/boot/core.bl")

    refute BeamLisp.Tiers.boot_source?("priv/std/errors.bl")
    refute BeamLisp.Tiers.build_source?("priv/std/errors.bl")

    # `toolchain_source?` is the union — what the barrier schedules serially.
    assert BeamLisp.Tiers.toolchain_source?("priv/boot/compiler.bl")
    assert BeamLisp.Tiers.toolchain_source?("priv/build/build-plan.bl")
    refute BeamLisp.Tiers.toolchain_source?("priv/std/errors.bl")
  end

  test "the tiers are disjoint, and the gate's own namespaces are tier-keyed" do
    boot = BeamLisp.Tiers.boot_namespaces()
    build = BeamLisp.Tiers.build_namespaces()

    assert Enum.sort(build) == [
             "app-resource",
             "build",
             "build-log",
             "build-plan",
             "claim",
             "deps",
             "deps-compile",
             "drop",
             "embed-asset",
             "hex",
             "mix-shim",
             "ns-interface",
             "pristine",
             "release",
             "seed",
             "selfbuild",
             "source-graph",
             "store",
             "substrate",
             "z3-asset"
           ]

    assert Enum.all?(build, &(&1 not in boot))

    # The drift gate runs on these; if one drifted into the wrong tier the gate
    # would compare it against the wrong key. `reader-node` is codegen; the
    # driver's own namespaces — the build, its planner, and the log they read
    # their state from — are the build tier.
    assert BeamLisp.Tiers.tier_of_ns("reader-node") == :boot
    assert BeamLisp.Tiers.tier_of_ns("build-plan") == :build
    assert BeamLisp.Tiers.tier_of_ns("source-graph") == :build
    assert BeamLisp.Tiers.tier_of_ns("ns-interface") == :build
    assert BeamLisp.Tiers.tier_of_ns("build-log") == :build
    assert BeamLisp.Tiers.tier_of_ns("substrate") == :build
    assert BeamLisp.Tiers.tier_of_ns("release") == :build
    assert BeamLisp.Tiers.tier_of_ns("drop") == :build
    assert BeamLisp.Tiers.tier_of_ns("pristine") == :build
    assert BeamLisp.Tiers.tier_of_ns("selfbuild") == :build
    assert BeamLisp.Tiers.tier_of_ns("datom") == :library
  end

  test "staged build refresh decision is narrow" do
    refute BeamLisp.BuildTask.refresh_staged_build?([])
    refute BeamLisp.BuildTask.refresh_staged_build?(["compiler", "reader"])
    assert BeamLisp.BuildTask.refresh_staged_build?(["compiler", "build"])
  end
end
