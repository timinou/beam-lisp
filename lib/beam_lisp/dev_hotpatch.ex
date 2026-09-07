defmodule BeamLisp.DevHotpatch do
  @moduledoc """
  Recompile boot-tier namespaces from CURRENT source inside the running VM —
  the iteration path for toolchain work that would otherwise need a seed
  regeneration (minutes) per edit.

      BL_HOTPATCH=compiler2,lower mix test test/beam_lisp/guards_test.exs
      BL_HOTPATCH=anf mix run --no-start my_probe.exs

  For each named namespace `foo`, this compiles `priv/boot/foo.bl` with the
  live seed toolchain (`BeamLisp.AOT.compile_file/2` into a temp dir —
  byte-identical to what a seed regen would write) and then swaps the emitted
  modules into the running VM with `:code.purge` + `:code.load_binary`. The
  namespace's vars were re-interned as a side effect of the compile, so both
  the var path and the direct `Ns.Body.*` path see the new code.

  This replaces the SEED only in this VM: `priv/bootstrap/seed` on disk is
  untouched. A seed regen is still the commit-time gate — this exists so the
  edit→test loop is seconds, not minutes.
  """

  require Logger

  @doc """
  Hot-patch the given boot namespaces (list of names like `"compiler2"`, or
  a comma-separated string) from `priv/boot/<name>.bl` sources.
  `:source_root` selects an explicit source snapshot for controlled comparisons.
  """
  def hotpatch!(names, opts \\ [])

  def hotpatch!(names, opts) when is_binary(names),
    do: names |> String.split(",", trim: true) |> hotpatch!(opts)

  def hotpatch!(names, opts) when is_list(names) do
    source_root = Keyword.get(opts, :source_root, "priv/boot")
    normalized = Enum.map(names, &to_string/1)
    Enum.each(normalized, fn name ->
      hotpatch_ns!(name, source_root)
      BeamLisp.Generation.record_hotpatch([name])
    end)
    :ok
  end

  @doc """
  Read `BL_HOTPATCH` and apply it. Called from `test_helper.exs`; safe to
  call when the variable is unset (no-op).
  """
  def apply_env! do
    case System.get_env("BL_HOTPATCH") do
      nil -> :ok
      "" -> :ok
      names -> hotpatch!(names)
    end
  end

  defp hotpatch_ns!(name, source_root) do
    path = Path.join(source_root, "#{name}.bl")
    unless File.exists?(path), do: raise("no boot source for namespace #{name}: #{path} not found")

    nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Path.join(System.tmp_dir!(), "bl_hotpatch_#{Path.basename(name)}_#{nonce}")
    File.mkdir_p!(dir)

    started = System.monotonic_time(:millisecond)
    emitted = BeamLisp.AOT.compile_file(path, output_dir: dir)
    beams = Enum.map(emitted, &elem(&1, 1))

    Enum.each(beams, fn beam ->
      mod = beam |> Path.basename(".beam") |> String.to_atom()
      :code.purge(mod)
      :code.delete(mod)
      {:module, ^mod} = :code.load_binary(mod, String.to_charlist(beam), File.read!(beam))
    end)

    ms = System.monotonic_time(:millisecond) - started
    Logger.info("hot-patched #{name}: #{length(beams)} beams, #{length(emitted)} modules emitted, #{ms}ms")
  end
end
