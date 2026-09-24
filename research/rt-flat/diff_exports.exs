# diff_exports.exs — every exported function the two runtimes share, called
# with every combination of values from a corpus, answer compared.
#
# The oracle calls each runtime through ONE hand-written row per operation, so
# it sees only what its rows name. Three defects shipped past it (`apply` and
# `list*` not spreading a vector, `drop`'s argument order) because no row named
# that shape or that order. This asks mechanically: for EVERY function both
# modules export at an arity, over a corpus of vectors, lazy seqs, nested lists
# and reader nodes, do they agree?
#
# Run against BUILT beams (both modules loaded):
#   elixir $(for d in build ~/.cache/beam_lisp/ebin/*/ebin; do echo -pa $d; done) \
#     research/rt-flat/diff_exports.exs
# Exit status 1 on any disagreement.

BeamLisp.Bootstrap.install!("build")
BeamLisp.AOT.boot()

old = BeamLisp.RT
new = BeamLisp.Ns.Rt
Code.ensure_loaded!(old)

vec = fn xs -> BeamLisp.Vector.new(xs) end
lazy = fn xs -> BeamLisp.LazySeq.new(fn -> xs end) end

corpus = [
  nil, true, false, 0, 1, -3, 2.5, "ab", "", :k, {:symbol, "s"},
  [], [1, 2, 3], [[1, 2], [3]], [:a, [1, 2]],
  vec.([]), vec.([1, 2, 3]), vec.([vec.([:a, 1]), vec.([:b, 2])]), vec.([{:symbol, "s"}, {:list, []}]),
  lazy.([1, 2]), %{}, %{a: 1}, BeamLisp.Set.new([1, 2]),
  {:list, [{:symbol, "f"}, 1]}, {:meta, {:symbol, "x"}, %{line: 1}}
]

# Functions as arguments: invoke, apply_to, map, filter, reduce … take one first.
fns = [fn x -> x end, fn x -> is_integer(x) end, fn a, b -> {a, b} end]

# Global state, processes, printing, nondeterminism: an answer says nothing.
skip = MapSet.new([
  :seed_core, :println, :println_multi, :gensym, :reader_macro!, :data_reader!,
  :module_info, :__info__, :__bl_init__, :__bl_provenance__, :trace_2, :untrace_1
])

shared =
  for {f, a} <- old.__info__(:functions),
      not MapSet.member?(skip, f),
      function_exported?(new, f, a),
      a in 1..3,
      do: {f, a}

realize = fn
  %BeamLisp.LazySeq{} = l -> {:lazy, BeamLisp.LazySeq.to_list(l)}
  x -> x
end

outcome = fn m, f, args ->
  task =
    Task.async(fn ->
      try do
        {:ok, realize.(apply(m, f, args))}
      rescue
        _ -> :raised
      catch
        _, _ -> :raised
      end
    end)

  case Task.yield(task, 500) || Task.shutdown(task, :brutal_kill) do
    {:ok, r} -> r
    _ -> :timeout
  end
end

arg_sets = fn
  1 -> for x <- corpus, do: [x]
  2 -> (for x <- corpus, y <- Enum.take(corpus, 12), do: [x, y]) ++ (for f <- fns, x <- corpus, do: [f, x])
  3 -> (for f <- fns, x <- Enum.take(corpus, 10), y <- Enum.take(corpus, 10), do: [f, x, y]) ++
         (for x <- Enum.take(corpus, 10), y <- Enum.take(corpus, 6), z <- Enum.take(corpus, 6), do: [x, y, z])
end

results =
  for {f, a} <- shared, args <- arg_sets.(a) do
    o = outcome.(old, f, args)
    n = outcome.(new, f, args)
    verdict =
      cond do
        o == n -> :agree
        o == :raised -> :new_more_total
        true -> :differ
      end
    {f, a, args, o, n, verdict}
  end

by = Enum.group_by(results, &elem(&1, 5))
IO.puts("functions compared: #{length(shared)}   calls: #{length(results)}")
for v <- [:agree, :new_more_total, :differ], do: IO.puts("  #{v}: #{length(Map.get(by, v, []))}")

differ = Map.get(by, :differ, [])

differ
|> Enum.group_by(fn {f, a, _, _, _, _} -> {f, a} end)
|> Enum.sort()
|> Enum.each(fn {{f, a}, rows} ->
  {_, _, args, o, n, _} = hd(rows)
  IO.puts("DIFFER #{f}/#{a} (#{length(rows)} calls) e.g. #{inspect(args, limit: 8) |> String.slice(0, 160)}")
  IO.puts("    old #{inspect(o, limit: 6) |> String.slice(0, 120)}")
  IO.puts("    new #{inspect(n, limit: 6) |> String.slice(0, 120)}")
end)

if differ != [], do: System.halt(1)
