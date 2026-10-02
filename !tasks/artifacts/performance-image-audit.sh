#!/bin/sh
# Read-only compiler-stamp audit, independent of application/source loading.
set -eu
ROOT=$(pwd -P)
export BL_ROOT="$ROOT" BL_EBIN="$ROOT/.bl/lib/beam_lisp-0.1.0/ebin"
exec elixir -pa "$BL_EBIN" -e '
k = BeamLisp.AOTCache.current_compiler_key()
IO.inspect(k, label: "CURRENT-COMPILER-KEY")
IO.inspect(BeamLisp.AOTCache.build_key(), label: "CURRENT-BUILD-KEY")
for {label, mod} <- [{:rt, BeamLisp.Ns.Rt}, {:core, BeamLisp.Ns.Core},
                     {:cli, BeamLisp.Ns.Bl.Cli}, {:native, BeamLisp.Ns.Vm.Native},
                     {:typed, BeamLisp.Ns.Typed}] do
  IO.inspect({label, BeamLisp.AOT.beam_provenance(mod)}, label: "STAMP")
end
counts = Path.wildcard(Path.join(System.fetch_env!("BL_EBIN"), "Elixir.BeamLisp.Ns.*.beam"))
|> Enum.reduce(%{}, fn path, acc ->
  case :beam_lib.chunks(String.to_charlist(path), [:attributes]) do
    {:ok, {_, [{:attributes, attrs}]}} ->
      case Keyword.get(attrs, :bl_compiler_key) do
        key when is_binary(key) -> Map.update(acc, key, 1, &(&1+1))
        [key] when is_binary(key) -> Map.update(acc, key, 1, &(&1+1))
        other -> Map.update(acc, {:unstamped, other}, 1, &(&1+1))
      end
    err -> raise inspect(err)
  end
end)
IO.inspect(counts, label: "ALL-NAMESPACE-BEAM-KEY-GROUPS")
'
