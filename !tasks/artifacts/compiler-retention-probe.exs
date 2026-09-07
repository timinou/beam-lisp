defmodule CompilerRetentionProbe do
  defp trace_lazy_sources(unit) do
    parent = self()
    collect = fn collect, counts ->
      receive do
        {:trace, _, :call, {m, f, args}, caller} ->
          collect.(collect, Map.update(counts, {m, f, length(args), caller}, 1, &(&1 + 1)))
        :finish -> send(parent, {:lazy_sources, counts})
      end
    end
    tracer = spawn(fn -> collect.(collect, %{}) end)
    patterns = for f <- [:map, :filter, :concat, :range], do: {BeamLisp.RT, f, :_}
    for pattern <- patterns, do: :erlang.trace_pattern(pattern, [{:_, [], [{:message, {:caller}}]}], [])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])
    try do
      unit.()
    after
      :erlang.trace(self(), false, [:call])
      for pattern <- patterns, do: :erlang.trace_pattern(pattern, false, [])
      delivery = :erlang.trace_delivered(self())
      receive do {:trace_delivered, _, ^delivery} -> :ok after 5000 -> raise "trace delivery timed out" end
      send(tracer, :finish)
      receive do {:lazy_sources, counts} -> IO.inspect(counts, label: "LAZY_COMPILER_CALLERS", limit: :infinity)
      after 5000 -> Process.exit(tracer, :kill); raise "trace collection timed out" end
    end
  end

  # No emitted modules are loaded or purged. Expected hashes compare both
  # repeated units and the baseline/eager generations in the same VM.
  def run(label, opts \\ []) do
    bindings = Enum.map_join(0..63, " ", fn i ->
      previous = if i == 0, do: "x", else: "v#{i - 1}"
      "v#{i} (+ #{previous} 1)"
    end)
    fixtures = [
      small: "(fn [x] (let [y (+ x 1)] (if (> y 3) [y x] [x y])))",
      large: "(fn [x] (let [#{bindings}] (if (> v63 3) [v63 x] [x v63])))"
    ]
    :code.ensure_loaded(BeamLisp.LazyMemo)
    :code.ensure_loaded(:cprof)
    :erlang.memory()
    results = Map.new(fixtures, fn {name, source} ->
      form = BeamLisp.Reader.read_one(source)
      env = BeamLisp.Compiler.new_env("compiler-retention-probe")
      unit = fn ->
        BeamLisp.Compiler.reset_fresh!()
        node = BeamLisp.Compiler.compile(form, env)
        descriptor = BeamLisp.Emit.descriptor_for(:bl_compiler_retention_probe,
          [BeamLisp.Emit.function_clause(:run, node)])
        {_mod, bytes} = BeamLisp.Emit.compile_descriptor(descriptor)
        :crypto.hash(:sha256, bytes)
      end
      expected = unit.()
      case Keyword.get(opts, :expected_hashes) do
        nil -> :ok
        hashes -> if Map.fetch!(hashes, name) != expected, do: raise("#{name}: refactor changed emitted bytes")
      end
      for batch <- 1..3 do
        modules_before = length(:code.all_loaded())
        :cprof.start(BeamLisp.LazySeq, :new, 1)
        {elapsed_us, hashes} = :timer.tc(fn -> for _ <- 1..10, do: unit.() end)
        :cprof.pause(BeamLisp.LazySeq, :new, 1)
        {_, registrations, _} = counts = :cprof.analyse(BeamLisp.LazySeq)
        :cprof.stop(BeamLisp.LazySeq, :new, 1)
        unless Enum.all?(hashes, &(&1 == expected)), do: raise("#{name}: repeated bytes differ")
        if Keyword.get(opts, :require_eager, true) and registrations != 0 do
          trace_lazy_sources(unit)
          raise("#{name}: compiler created #{registrations} lazy memo handles")
        end
        # One post-batch measurement GC, never a cache clear or module purge.
        :erlang.garbage_collect()
        memo = if function_exported?(BeamLisp.LazyMemo, :stats, 0), do: BeamLisp.LazyMemo.stats(), else: :unavailable
        IO.inspect(%{generation: label, fixture: name, batch: batch, units: 10,
          elapsed_us: elapsed_us, process_memory: Process.info(self(), :memory),
          vm_memory: :erlang.memory(), memo: memo, lazy_registrations: counts,
          loaded_module_delta: length(:code.all_loaded()) - modules_before},
          label: "COMPILER_RETENTION", limit: :infinity)
      end
      {name, expected}
    end)
    IO.inspect(BeamLisp.Generation.receipt(), label: "RETENTION_GENERATION_#{label}", limit: :infinity)
    results
  end
end
