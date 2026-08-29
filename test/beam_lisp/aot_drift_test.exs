defmodule BeamLisp.AotDriftTest do
  use ExUnit.Case, async: false

  # Wave 1 / L2 regression gate: a stale AOT `.beam` must never be trusted.
  #
  # This forges the exact desync that produced the original bug — a compiled
  # module on the code path whose SOURCE has since changed (a new `defn` added),
  # while the beam predates it. The drift gate in `AOT.ensure_loaded/1` reads the
  # beam's `__bl_provenance__/0` stamp, compares to the live source hash, and:
  #
  #   * dev (default)          → returns `:no_module`, so the loader falls to the
  #                              SOURCE path and the new def is present (auto-heal)
  #   * BEAM_LISP_AOT_STRICT=1  → raises a loud, actionable error (refuse)
  #
  # Without the gate, `ensure_loaded` would run the stale beam's `__bl_init__/0`,
  # the new var would never intern, and a call to it would raise
  # `undefined var: drift.fixture/added` — the field failure this closes.

  @tmp Path.join(System.tmp_dir!(), "beam_lisp_drift_fixture")
  @src_dir Path.join(@tmp, "src")
  @out Path.join(@tmp, "out")

  @ns "drift.fixture"
  @mod BeamLisp.Ns.Drift.Fixture
  @src Path.join(@src_dir, "drift/fixture.bl")

  # v1: only `base`. v2: adds `added`, which a stale v1 beam cannot provide.
  @v1 """
  (ns drift.fixture)
  (defn base [] :v1)
  """
  @v2 """
  (ns drift.fixture)
  (defn base [] :v2)
  (defn added [] :new)
  """

  setup do
    # The gate reads live var/loaded state through the `BeamLisp.Env` Agent and
    # `Loader.Server`. Both are supervised, but a sibling suite that stops the
    # app (or a linked owner exiting) can leave them dead for a later test. Own
    # them here so the gate always has live processes regardless of run order:
    # start unlinked and register, tolerating an already-running instance.
    ensure_named(BeamLisp.Env, fn -> BeamLisp.Env.start_link([]) end)
    ensure_named(BeamLisp.Loader.Server, fn -> BeamLisp.Loader.Server.start_link([]) end)
    BeamLisp.init()
    File.rm_rf!(@tmp)
    File.mkdir_p!(Path.dirname(@src))
    Code.append_path(@out)
    on_exit(fn -> File.rm_rf!(@tmp) end)
    :ok
  end

  defp compile!(source) do
    File.write!(@src, source)
    Mix.Tasks.Compile.BeamLisp.clean(@out)

    assert {:ok, _} =
             Mix.Tasks.Compile.BeamLisp.run(["--source-dir", @src_dir, "--out", @out])
  end

  # Reload the freshly-emitted beam into THIS VM, replacing any prior version,
  # so `Code.ensure_loaded?` + `__bl_provenance__/0` read the on-disk module.
  # Ensure a named process is alive, starting it (unlinked) if not. Tolerates
  # `{:already_started, _}` from a supervised instance. Unlinked so this test
  # process exiting does not take the process down for the next test.
  defp ensure_named(name, start) do
    case Process.whereis(name) do
      nil ->
        {:ok, pid} =
          case start.() do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
          end

        Process.unlink(pid)
        :ok

      _pid ->
        :ok
    end
  end

  defp reload_beam! do
    :code.purge(@mod)
    :code.delete(@mod)
    path = Path.join(@out, Atom.to_string(@mod) <> ".beam")
    bin = File.read!(path)
    {:module, @mod} = :code.load_binary(@mod, String.to_charlist(path), bin)
    :ok
  end

  # Forge the drift desync: build v1, keep its (v1-stamped) beam bytes, move
  # the SOURCE to v2 (adds `added`), then drop the v1 beam back on disk and
  # into this VM. The exact state a branch-switch / shared `_build` leaves:
  # beam predates source. Returns with @mod loaded as the stale v1 beam.
  defp forge_stale! do
    compile!(@v1)
    beam_file = Path.join(@out, Atom.to_string(@mod) <> ".beam")
    v1_beam = File.read!(beam_file)
    File.write!(@src, @v2)
    File.write!(beam_file, v1_beam)
    reload_beam!()
  end

  test "a fresh beam is not stale — provenance matches source" do
    compile!(@v2)
    reload_beam!()

    # The stamp equals the live source hash, so the gate trusts it.
    {stamp, key} = apply(@mod, :__bl_provenance__, [])
    live = :crypto.hash(:sha256, File.read!(@src)) |> Base.encode16()
    assert stamp == live
    assert key == BeamLisp.AOTCache.compiler_key()
  end

  test "dev: the drift gate routes a stale beam to the source path (:no_module)" do
    forge_stale!()

    # The on-disk beam is v1 (no `added`); the source is v2 — hashes differ.
    {stamp, _} = apply(@mod, :__bl_provenance__, [])
    live = :crypto.hash(:sha256, File.read!(@src)) |> Base.encode16()
    refute stamp == live, "precondition: beam must be stale vs source"

    # Drift detected → :no_module, so `Loader` falls to the SOURCE path. The
    # gate resolves the live source hash via find_file, which needs the loader
    # server context + the pinned search dir.
    Process.put(:bl_search_dirs, [@src_dir])
    result = BeamLisp.AOT.ensure_loaded(@ns)

    assert result == :no_module
  end

  test "dev: a fresh VM with a stale beam auto-heals — the added var exists" do
    # The honest original-bug scenario: a brand-new VM whose ONLY view of the
    # namespace is a stale beam + newer source. The full loader (AOT-first,
    # source-fallback) must land on v2, so `added` resolves. Run in a
    # subprocess so no prior in-process load pollutes the result (wave9 idiom).
    forge_stale!()

    # The changed source must be on the loader's REAL search path (it captures
    # `[cwd] ++ BEAM_LISP_PATH`, not an ad-hoc pin), so expose @src_dir via
    # BEAM_LISP_PATH — exactly how a dev's edited source is already reachable.
    script = """
    Application.load(:beam_lisp)
    {:ok, _} = BeamLisp.Env.start_link([])
    {:ok, _} = BeamLisp.Loader.Server.start_link([])
    BeamLisp.init()
    BeamLisp.Loader.ensure_loaded(#{inspect(@ns)})
    IO.puts("base=" <> inspect(BeamLisp.eval("(drift.fixture/base)")))
    IO.puts("added=" <> inspect(BeamLisp.eval("(drift.fixture/added)")))
    """

    {out, 0} =
      System.cmd(
        "elixir",
        ["-pa", Mix.Project.compile_path(), "-pa", @out, "-e", script],
        stderr_to_stdout: true,
        env: [{"BEAM_LISP_PATH", @src_dir}]
      )

    # Without the drift gate the stale beam's __bl_init__ would run, `added`
    # would never intern, and this would print an `undefined var` error.
    assert out =~ "base=:v2", out
    assert out =~ "added=:new", out
  end

  test "strict: a stale beam refuses loud instead of healing" do
    forge_stale!()

    # `compile.beam_lisp` (inside forge_stale!) can leave the supervised Env/
    # Loader.Server down; re-own them so the gate's `loaded_ns?` has a live
    # Agent at the point of use.
    ensure_named(BeamLisp.Env, fn -> BeamLisp.Env.start_link([]) end)
    ensure_named(BeamLisp.Loader.Server, fn -> BeamLisp.Loader.Server.start_link([]) end)

    System.put_env("BEAM_LISP_AOT_STRICT", "1")

    on_exit(fn -> System.delete_env("BEAM_LISP_AOT_STRICT") end)

    assert_raise RuntimeError, ~r/stale AOT beam for drift\.fixture/, fn ->
      Process.put(:bl_search_dirs, [@src_dir])
      BeamLisp.AOT.ensure_loaded(@ns)
    end
  end
end
