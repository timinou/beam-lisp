defmodule BeamLisp.BootNamespaceTest do
  use ExUnit.Case, async: false

  test "action-only boot files are compiled but never demanded as namespace beams" do
    namespaces = BeamLisp.Tiers.boot_namespaces()
    assert "compiler" in namespaces
    assert "reader" in namespaces
    assert "core" in namespaces
    refute "data-readers" in namespaces
    assert Enum.any?(BeamLisp.Tiers.sources(), &String.ends_with?(&1, "/boot/data-readers.bl"))
  end

  test "provenance loads a cold namespace before testing its export" do
    root = Path.join(System.tmp_dir!(), "bl-cold-provenance-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    [{module, beam}] = Code.compile_string("defmodule BeamLisp.ColdProvenanceFixture do\n def __bl_provenance__, do: {\"source\", \"generation\"}\nend")
    :code.purge(module)
    :code.delete(module)
    File.write!(Path.join(root, Atom.to_string(module) <> ".beam"), beam)
    Code.prepend_path(root)
    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
      Code.delete_path(root)
      File.rm_rf!(root)
    end)
    refute function_exported?(module, :__bl_provenance__, 0)
    assert BeamLisp.AOT.beam_provenance(module) == {"source", "generation"}
  end

  test "seed namespace inventory follows declarations, not filenames" do
    BeamLisp.init()
    root = Path.join(System.tmp_dir!(), "bl-seed-names-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "different-file.bl"), "(ns sample-boot)\n(def value 1)\n")
    File.write!(Path.join(root, "data-readers.bl"), "(println :action-only)\n")
    BeamLisp.Loader.ensure_loaded("seed")
    names = BeamLisp.RT.invoke(BeamLisp.Env.fetch!("seed", "namespaces"), [root]) |> Enum.to_list()
    assert Enum.sort(names) == Enum.sort(["Sample-boot", "Multi"])
  end
end
