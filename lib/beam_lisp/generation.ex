defmodule BeamLisp.Generation do
  @moduledoc """
  Identifies source, committed seed and live compiler code independently.

  Code-path object bytes may differ from an in-memory hotpatch. Live module
  MD5 and object-file SHA-256 are therefore reported separately.
  """

  @hotpatch_key {__MODULE__, :hotpatched_namespaces}
  @loaded_modules [BeamLisp.Ns.Compiler2, BeamLisp.Ns.Lower, BeamLisp.Ns.Anf]

  @doc "Return a machine-readable generation receipt without loading compiler modules."
  def receipt(opts \\ []) do
    %{
      source: %{
        codegen_key: BeamLisp.AOTCache.current_compiler_key(),
        memoized_codegen_key: BeamLisp.AOTCache.compiler_key()
      },
      seed: seed_identity(),
      loaded: %{modules: Map.new(Keyword.get(opts, :modules, @loaded_modules), &module_identity/1)},
      hotpatched_namespaces: hotpatched_namespaces(),
      build: %{
        mix_env: if(Process.whereis(Mix.State), do: to_string(Mix.env()), else: "release"),
        aot_backend: Atom.to_string(BeamLisp.AOTCache.aot_backend())
      },
      cache: %{
        mode: if(System.get_env("BEAM_LISP_AOT_STRICT") in ["1", "true"], do: "strict", else: "fallback"),
        directory: System.get_env("BEAM_LISP_AOT_CACHE_DIR"),
        enabled: System.get_env("BEAM_LISP_AOT_CACHE") != "off"
      }
    }
  end

  @doc false
  def record_hotpatch(names) when is_list(names) do
    updated = (hotpatched_namespaces() ++ Enum.map(names, &to_string/1)) |> Enum.uniq() |> Enum.sort()
    :persistent_term.put(@hotpatch_key, updated)
    :ok
  end

  @doc false
  def reset_hotpatches, do: :persistent_term.erase(@hotpatch_key)

  defp hotpatched_namespaces, do: :persistent_term.get(@hotpatch_key, [])

  defp module_identity(mod) do
    # get_object_code reads the code path, not necessarily the running module.
    live_md5 = if :code.is_loaded(mod) != false, do: apply(mod, :module_info, [:md5]), else: nil

    object =
      case :code.get_object_code(mod) do
        {^mod, bytes, path} ->
          %{
            sha256: sha256(bytes),
            path: path |> to_string() |> Path.expand(),
            matches_loaded: live_md5 != nil and :code.module_md5(bytes) == live_md5
          }
        :error -> nil
      end

    {Atom.to_string(mod), %{
      loaded_md5: if(live_md5, do: Base.encode16(live_md5, case: :lower)),
      object_code: object
    }}
  end

  defp seed_identity do
    path = Path.join(seed_dir(), "manifest.exs")
    case File.read(path) do
      {:ok, bytes} -> %{manifest_sha256: sha256(bytes), path: Path.expand(path)}
      {:error, reason} -> %{manifest_sha256: nil, path: Path.expand(path), error: Atom.to_string(reason)}
    end
  end

  defp seed_dir do
    case :code.priv_dir(:beam_lisp) do
      dir when is_list(dir) -> Path.join(to_string(dir), "bootstrap/seed")
      _ -> Path.expand("priv/bootstrap/seed")
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
