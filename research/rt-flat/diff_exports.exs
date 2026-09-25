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
# BeamLisp.RT is gone from the tree, so the reference is a preserved beam of it
# (built from any pre-cutover commit, e.g. f1f6bfdf): put its directory on -pa.
#   elixir $(for d in build ~/.cache/beam_lisp/ebin/*/ebin; do echo -pa $d; done) \
#     -pa DIR_WITH_OLD_RT_BEAM research/rt-flat/diff_exports.exs [--fresh]
# Exit status 1 on any disagreement.

BeamLisp.Bootstrap.install!("build")
BeamLisp.AOT.boot()

# `--fresh`: compile priv/boot/rt.bl into this VM first, so the diff is of the
# SOURCE, not of the last build — seconds instead of a tier rebuild.
if "--fresh" in System.argv() do
  root = File.cwd!()
  BeamLisp.Env.add_search_path(Path.join(root, "priv/boot"))
  BeamLisp.Env.add_search_path(Path.join(root, "priv/std"))
  BeamLisp.Loader.ensure_loaded("build")
  out = Path.join(System.tmp_dir!(), "diff-exports-rt")
  File.rm_rf!(out)
  File.mkdir_p!(out)
  BeamLisp.AOT.compile_file(Path.join(root, "priv/boot/rt.bl"), output_dir: out)
end

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
  :module_info, :__info__, :__bl_init__, :__bl_provenance__, :trace_2, :untrace_1,
  # a message builder the compiler calls with an INTEGER arity only; the corpus
  # passes it arbitrary values, and RT's answer there is Elixir interpolating a
  # nil — not a contract
  :call_shape_error
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
      # The exception TYPE is part of the contract: a caller's `rescue
      # BeamLisp.CompileError` or `(catch ArgumentError …)` depends on it. The
      # first version compared only raise/no-raise, and a capability refusal
      # raised as a bare tuple passed as "agree".
      try do
        {:ok, realize.(apply(m, f, args))}
      rescue
        e -> {:raised, e.__struct__}
      catch
        kind, _ -> {:raised, kind}
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
    # A DELIBERATE refusal type is part of the contract (a caller rescues it by
    # name): ArgumentError, BeamLisp.CompileError, BeamLisp.ExInfo. An
    # incidental one — CaseClauseError, Protocol.UndefinedError, a BIF's
    # badarg surfacing as ArgumentError from deep inside Enum — is how RT
    # happened to fail, and nothing can rescue it meaningfully; those compare as
    # "raised".
    contract = [BeamLisp.CompileError, BeamLisp.ExInfo]
    norm = fn
      {:raised, t} -> if t in contract, do: {:raised, t}, else: :raised
      x -> x
    end
    {o, n} = {norm.(o), norm.(n)}
    verdict =
      cond do
        o == n -> :agree
        (o == :raised or match?({:raised, _}, o)) and not (n == :raised or match?({:raised, _}, n)) -> :new_more_total
        # RT crashed incidentally where the BL runtime raises the CONTRACT error
        o == :raised and match?({:raised, _}, n) -> :new_more_total
        true -> :differ
      end
    {f, a, args, o, n, verdict}
  end

# Departures the oracle DECLARES, each with its reason there
# (research/rt-cutover/oracle.bl `declared`); a disagreement matching one is
# accounted for, not a defect.
seq_fam? = fn x -> is_list(x) or match?(%BeamLisp.Vector{}, x) or match?(%BeamLisp.LazySeq{}, x) end
empty_res? = fn {:ok, %BeamLisp.Vector{items: {}}}, {:ok, []} -> true; _, _ -> false end
declared? = fn
  # sequential-family-is-one-value
  {f, _, [a, b], _, _, _} when f in [:eqv, :compare] and is_list(a) and is_list(b) -> true
  {f, _, [a, b], _, _, _} when f in [:eqv, :compare] ->
    (seq_fam?.(a) and seq_fam?.(b)) or
      # family-rank orders identities (fns, pids, refs) after data tuples;
      # RT ranked a tuple (12) after a function (9). Order between families is
      # the policy table's call, and neither is equal to the other either way.
      ((is_function(a) and is_tuple(b)) or (is_tuple(a) and is_function(b))) or
      # a {:meta form m} reader wrapper compares as its form (same policy, rt.bl `unwrap-meta`)
      match?({:meta, _, _}, a) or match?({:meta, _, _}, b)
  # rt-empty-result-is-a-VECTOR, and rt-yields-raw-tuple-entries: sort walks a
  # map through RT's seqable
  {f, _, args, o, n, _} when f in [:sort, :take] ->
    empty_res?.(o, n) or Enum.any?(args, &(is_map(&1) and not is_struct(&1)))

  # rt-yields-raw-tuple-entries
  {:sorted_set_of, _, [m], _, _, _} -> is_map(m) and not is_struct(m)
  # a transducer is a FRESH closure per call: two are never ==, in either runtime
  {f, _, _, {:ok, o}, {:ok, n}, _} when f in [:map_xform, :filter_xform, :take_xform] -> is_function(o) and is_function(n)
  _ -> false
end
results = Enum.map(results, fn {f, a, args, o, n, :differ} = r -> if declared?.(r), do: {f, a, args, o, n, :declared}, else: r; r -> r end)

by = Enum.group_by(results, &elem(&1, 5))
IO.puts("functions compared: #{length(shared)}   calls: #{length(results)}")
for v <- [:agree, :new_more_total, :declared, :differ], do: IO.puts("  #{v}: #{length(Map.get(by, v, []))}")

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
