# Migration only: convert quoted definition slots within the frozen ANF,
# never outputs from the live compiler. Run before legacy importer deletion.
# Version 1 fixtures remain immutable historical evidence.
defmodule FrozenCanonicalCorpusMigration do
  def rewrite(%{op: :lit} = node), do: node
  def rewrite(%{pop: :plit} = node), do: node

  def rewrite(%{op: :struct, pairs: pairs} = node),
    do: node |> Map.delete(:pairs) |> Map.put(:fields, pairs) |> rewrite()

  def rewrite(%{pop: :pstruct, pairs: pairs} = node),
    do: node |> Map.delete(:pairs) |> Map.put(:fields, pairs) |> rewrite()

  def rewrite(%{op: :remote, mod: BeamLisp.Link, fun: :defvar, args: [ns, name, definitions | rest]} = node) do
    interpreter = BeamLisp.Env.fetch!("self.anf", "interp")
    entries = BeamLisp.RT.invoke(interpreter, [definitions, %{}])
    canonical = Enum.map(entries, fn {kind, arity, fname, quoted} ->
      [clause] = apply(BeamLisp.Ns.Lower, :"bootstrap-import-definitions", [[quoted]])
      {kind, arity, fname, rewrite(clause)}
    end)
    %{node | args: [rewrite(ns), rewrite(name), BeamLisp.Emit.lit(canonical) | Enum.map(rest, &rewrite/1)]}
  end

  def rewrite(value) when is_map(value), do: Map.new(:maps.to_list(value), fn {k, v} -> {k, rewrite(v)} end)
  def rewrite(value) when is_list(value), do: Enum.map(value, &rewrite/1)
  def rewrite(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&rewrite/1) |> List.to_tuple()
  def rewrite(value), do: value
end

output = "test/fixtures/anf_canonical_corpus"
File.mkdir_p!(output)
for path <- Path.wildcard("test/fixtures/anf_corpus/*.etf"),
    not File.exists?(Path.join(output, Path.basename(path))) do
  %{version: 1, source: source, entries: entries} =
    path |> File.read!() |> :erlang.binary_to_term()

  migrated = Enum.map(entries, fn {form, {:ok, %{op: _} = frozen_anf}} ->
    node = FrozenCanonicalCorpusMigration.rewrite(frozen_anf)
    {form, {:ok, node}}
  end)

  payload = %{version: 2, source: source, entries: migrated}
  bytes = :erlang.term_to_binary(payload, [:compressed])
  target = Path.join(output, Path.basename(path))
  case File.read(target) do
    {:ok, ^bytes} -> :ok
    {:ok, existing} ->
      unless :erlang.binary_to_term(existing) === payload do
        candidate = Path.join(System.tmp_dir!(), "candidate_#{Path.basename(target)}")
        File.write!(candidate, bytes)
        raise "refusing to replace differing canonical fixture #{target}; candidate: #{candidate}"
      end
    {:error, :enoent} -> File.write!(target, bytes, [:exclusive])
    {:error, reason} -> raise "cannot read #{target}: #{inspect(reason)}"
  end
  IO.puts("MIGRATED_FROZEN_ORACLE #{source}: #{length(migrated)} forms")
end
