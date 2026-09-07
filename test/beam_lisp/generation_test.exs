defmodule BeamLisp.GenerationTest do
  use ExUnit.Case, async: false

  alias BeamLisp.Generation

  setup do
    Generation.reset_hotpatches()
    on_exit(&Generation.reset_hotpatches/0)
    :ok
  end

  test "receipt separates current source, committed seed, and actually loaded code" do
    Enum.each([BeamLisp.Ns.Compiler, BeamLisp.Ns.Lower, BeamLisp.Ns.Anf], &Code.ensure_loaded!/1)
    receipt = Generation.receipt()

    assert receipt.source.codegen_key == BeamLisp.AOTCache.current_compiler_key()
    assert is_binary(receipt.seed.manifest_sha256)
    assert byte_size(receipt.seed.manifest_sha256) == 64

    for mod <- [BeamLisp.Ns.Compiler, BeamLisp.Ns.Lower, BeamLisp.Ns.Anf] do
      identity = receipt.loaded.modules[Atom.to_string(mod)]
      assert %{loaded_md5: loaded_md5, object_code: %{sha256: hash, path: path}} = identity
      assert loaded_md5 == Base.encode16(apply(mod, :module_info, [:md5]), case: :lower)
      assert byte_size(hash) == 64
      assert is_binary(path)

      {^mod, bytes, _} = :code.get_object_code(mod)
      assert hash == (:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))
    end
  end

  test "in-memory replacement is not reported as the stale object file" do
    mod = :bl_generation_receipt_fixture
    dir = Path.join(System.tmp_dir!(), "bl_generation_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    :code.add_patha(String.to_charlist(dir))
    on_exit(fn ->
      :code.purge(mod)
      :code.delete(mod)
      :code.del_path(String.to_charlist(dir))
      File.rm_rf!(dir)
    end)

    build = fn value ->
      forms = [{:attribute, 1, :module, mod}, {:attribute, 1, :export, [{:value, 0}]},
               {:function, 1, :value, 0, [{:clause, 1, [], [], [{:atom, 1, value}]}]}]
      {:ok, ^mod, bytes} = :compile.forms(forms, [:binary])
      bytes
    end

    old_bytes = build.(:old)
    new_bytes = build.(:new)
    file = Path.join(dir, "#{mod}.beam")
    File.write!(file, old_bytes)
    {:module, ^mod} = :code.load_binary(mod, String.to_charlist(file), new_bytes)
    identity = Generation.receipt(modules: [mod]).loaded.modules[Atom.to_string(mod)]
    assert apply(mod, :value, []) == :new
    assert identity.loaded_md5 == Base.encode16(:code.module_md5(new_bytes), case: :lower)
    assert identity.object_code.sha256 == Base.encode16(:crypto.hash(:sha256, old_bytes), case: :lower)
    refute identity.object_code.matches_loaded
  end

  test "hotpatch receipt names only successfully recorded namespaces" do
    assert Generation.receipt().hotpatched_namespaces == []
    assert :ok = Generation.record_hotpatch(["lower", "compiler", "lower"])
    assert Generation.receipt().hotpatched_namespaces == ["compiler", "lower"]
  end

  test "receipt exposes build and cache modes without conflating them with identity" do
    receipt = Generation.receipt()

    assert receipt.build.aot_backend in ["core", "elixir"]
    assert receipt.build.mix_env in ["dev", "test", "prod"]
    assert receipt.cache.mode in ["fallback", "strict"]
    refute Map.has_key?(receipt.source, :hotpatched_namespaces)
    refute Map.has_key?(receipt.loaded, :seed)
  end
end
