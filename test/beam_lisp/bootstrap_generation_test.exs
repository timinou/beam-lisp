defmodule BeamLisp.BootstrapGenerationTest do
  use ExUnit.Case, async: false

  @shim BeamLisp.Ns.GenerationProbe
  @body BeamLisp.Ns.Body.GenerationProbe

  setup do
    root = Path.join(System.tmp_dir!(), "bl_seed_gate_#{System.unique_integer([:positive])}")
    seed = Path.join(root, "seed")
    ebin = Path.join(root, "ebin")
    File.mkdir_p!(seed)
    File.mkdir_p!(ebin)
    staging = Application.fetch_env(:beam_lisp, :bootstrap_staging)
    on_exit(fn ->
      Enum.each([@shim, @body], fn mod -> :code.purge(mod); :code.delete(mod) end)
      case staging do
        {:ok, value} -> Application.put_env(:beam_lisp, :bootstrap_staging, value)
        :error -> Application.delete_env(:beam_lisp, :bootstrap_staging)
      end
      File.rm_rf!(root)
    end)
    %{seed: seed, ebin: ebin}
  end

  test "a previous seed cannot overwrite a complete current generation", %{seed: seed, ebin: ebin} do
    write_seed(seed)
    key = BeamLisp.AOTCache.compiler_key()
    fresh_shim = beam(@shim, :fresh, key)
    fresh_body = beam(@body, :fresh, nil)
    File.write!(path(ebin, @shim), fresh_shim)
    File.write!(path(ebin, @body), fresh_body)
    stamp = {{2026, 1, 1}, {0, 0, 0}}
    File.touch!(path(ebin, @shim), stamp)
    File.touch!(path(ebin, @body), stamp)

    assert {:staged, :compiler_key_mismatch} = BeamLisp.Bootstrap.install!(ebin, seed_dir: seed)
    assert File.read!(path(ebin, @shim)) == fresh_shim
    assert File.read!(path(ebin, @body)) == fresh_body
    assert apply(@shim, :value, []) == :fresh
    assert apply(@body, :value, []) == :fresh
  end

  test "an incomplete generation cannot protect an older companion", %{seed: seed, ebin: ebin} do
    write_seed(seed)
    File.write!(path(ebin, @shim), beam(@shim, :fresh, BeamLisp.AOTCache.compiler_key()))
    File.write!(path(ebin, @body), beam(@body, :interrupted, nil))
    File.touch!(path(ebin, @shim), {{2026, 1, 2}, {0, 0, 0}})
    File.touch!(path(ebin, @body), {{2026, 1, 1}, {0, 0, 0}})

    BeamLisp.Bootstrap.install!(ebin, seed_dir: seed)
    assert apply(@body, :value, []) == :seed
    assert File.read!(path(ebin, @body)) == File.read!(path(seed, @body))
  end

  test "corrupt seed bytes refuse installation", %{seed: seed, ebin: ebin} do
    write_seed(seed)
    File.write!(path(seed, @shim), "not a beam")
    assert_raise RuntimeError, ~r/checksum mismatch/, fn ->
      BeamLisp.Bootstrap.install!(ebin, seed_dir: seed)
    end
    refute File.exists?(path(ebin, @shim))
  end

  defp write_seed(seed) do
    modules = Enum.map([@shim, @body], fn mod ->
      bytes = beam(mod, :seed, if(mod == @shim, do: "previous-generation"))
      File.write!(path(seed, mod), bytes)
      {Atom.to_string(mod) <> ".beam", Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
    end)
    File.write!(Path.join(seed, "manifest.exs"), inspect(%{"compiler_key" => "previous-generation", "modules" => Map.new(modules)}))
  end

  defp beam(mod, value, key) do
    value_fn = {:function, 1, :value, 0, [{:clause, 1, [], [], [:erl_parse.abstract(value)]}]}
    provenance = if key do
      [{:function, 1, :__bl_provenance__, 0, [{:clause, 1, [], [], [:erl_parse.abstract({nil, key})]}]}]
    else
      []
    end
    exports = [{:value, 0}] ++ if(key, do: [{:__bl_provenance__, 0}], else: [])
    forms = [{:attribute, 1, :module, mod}, {:attribute, 1, :export, exports}, value_fn] ++ provenance
    {:ok, ^mod, bytes} = :compile.forms(forms, [:binary])
    bytes
  end

  defp path(root, mod), do: Path.join(root, Atom.to_string(mod) <> ".beam")
end
