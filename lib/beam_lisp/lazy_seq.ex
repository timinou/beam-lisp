defmodule BeamLisp.LazySeq do
  @moduledoc """
  A lazily-realized sequence — the Clojure seq model, native on the BEAM.

  A `LazySeq` holds a zero-arity thunk. Forcing it produces either `nil`
  (empty) or a `[head | tail]` cell whose `tail` is itself a `LazySeq` or a
  realized list, so a lazy seq is a chain of deferred cells that each realize
  exactly when they are reached.

  **Thunk contract — what a lazy-seq body may return:** `nil`, a `[h | t]`
  cons cell, any seqable collection (vector, set), or a bare `LazySeq`.
  Returning a bare `LazySeq` is idiomatic — Clojure `lazy-seq` bodies
  routinely hand back another seq (`(lazy-seq (concat …))`) — and
  `realize/1` peels such nested nodes until it finds `nil` or a cons cell.
  **What the type guarantees to callers:** `cell/1` and `realize/1` always
  yield `nil` or a `[h | t]` cell — never a bare `LazySeq` — so every walk
  (concat, first, next, take, count, Enum) can pattern-match on exactly those
  two shapes. Only the head is normalized; the tail stays lazy, so an infinite
  seq realizes one cell at a time.

  Realization is memoized **once per node** so re-forcing a shared cell never
  re-runs its thunk (the guarantee Clojure's `lazy-seq` makes): each node
  carries a unique `:ref` key and writes its realized value into the shared
  vars ETS table the first time the thunk runs. The trade-off against a
  process/`Agent`-per-cell is that it is lock-free and cheap for hot `take`/
  `doall` loops; the trade-off against pure functional rebind is that a
  realized cell's cache entry lives for the process lifetime (bounded by the
  number of distinct lazy cells realized, not by re-traversals). An `:atomics`
  slot was the first candidate but holds integers only, so it cannot store a
  realized cell.

  Implements `Enumerable` and `Inspect`: the former lets lazy seqs flow into
  Elixir's `Enum`/`Stream` unchanged, the latter prints a bounded prefix
  (`(1 2 3 …)`) so an infinite seq can never hang the printer.
  """

  # The realization cache lives in its OWN table, not in the shared var
  # table. An ETS table dies with the process that created it, and the
  # var table is created by (and so owned by) the `Env` Agent — so an
  # Env restart silently discarded every memoized chunk. A seq that had
  # realized 32 elements went back to realizing one at a time: not an
  # error, just the memo quietly gone, which is why it surfaced as an
  # intermittent laziness test failure correlated with machine load
  # rather than as anything diagnosable (BUG-011).
  #
  # Memoization state and var state have different lifetimes. Keeping
  # them in one table coupled them.
  @table :beam_lisp_lazy_cache

  # Chunked seq fns realize this many elements per thunk, so the
  # per-element LazySeq allocation is amortized instead of one struct +
  # closure per element (the reason Clojure chunks at 32).
  @chunk_size 32

  defstruct key: nil, thunk: nil

  @type t :: %__MODULE__{key: reference(), thunk: (-> term)}

  @doc "Wrap `thunk` in a lazy seq node, realized at most once."
  def new(thunk) when is_function(thunk, 0) do
    %__MODULE__{key: make_ref(), thunk: thunk}
  end

  @doc "Interop alias for the `lazy-seq` macro's `BeamLisp.LazySeq/from_fun` call."
  def from_fun(thunk) when is_function(thunk, 0), do: new(thunk)

  @doc "Is `x` a lazy seq?"
  def lazy?(%__MODULE__{}), do: true
  def lazy?(_), do: false

  @doc "The chunk size for chunked realization (32, as in Clojure)."
  def chunk_size, do: @chunk_size

  @doc """
  Build a realized cons chain `e1 | e2 | … | ek | <lazy tail>` from the
  non-empty proper list `elems` (k ≤ `@chunk_size`) and a 0-arity `tail_fun`
  producing the next segment (or nil). Chunked seq fns return one of these
  from a single thunk: a consumer that stops inside the chunk (like `take 5`)
  never forces the tail, while each element past the first costs only a cons
  cell instead of a fresh LazySeq node.
  """
  def chain([], _tail_fun), do: nil

  def chain(elems, tail_fun) when is_function(tail_fun, 0) do
    List.foldr(elems, new(tail_fun), fn e, acc -> [e | acc] end)
  end

  @doc "Run a node's thunk exactly once, caching and returning the result."
  def force(%__MODULE__{key: key, thunk: thunk}) do
    ensure_table()

    case :ets.lookup(@table, {:lazy, key}) do
      [{_, value}] ->
        value

      [] ->
        value = thunk.()
        :ets.insert(@table, {{:lazy, key}, value})
        value
    end
  end

  # Created on first use. The creator MUST be a VM-lifetime process: under
  # async test suites the first toucher was a short-lived per-file Task, the
  # table died with it, and every later lazy-seq access VM-wide raised
  # "the table identifier does not refer to an existing ETS table" — flaky,
  # order-dependent (PLAN-047 W1). The pinned Loader.Server owns it.
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        BeamLisp.Loader.Server.run(fn ->
          try do
            :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          rescue
            # Another process won the race; its table is the one we want.
            ArgumentError -> :ok
          end
        end)

      _ ->
        :ok
    end
  end

  @doc "Force a node and normalize to a realized cell: `nil` or `[head | tail]`."
  def realize(%__MODULE__{} = l), do: realize_loop(l, 0)

  # A lazy-seq body may hand back any seqable rather than a cons cell —
  # jank writes `(lazy-seq c1)` around a bare collection — so normalize
  # it here, at the one place a thunk's value enters the walk. Without
  # this a realized vector reached the walk loops as an opaque value and
  # crashed with no matching clause.
  #
  # The invariant every walk relies on is: forcing a node yields `nil`
  # or a `[h | t]` cell, never a bare LazySeq. Clojure `lazy-seq` bodies
  # routinely *return another seq* — `(lazy-seq (concat …))` nests — so
  # a thunk that hands back a bare LazySeq is idiomatic, not an error.
  # Peel those nested nodes here rather than leaving them for every
  # `case LazySeq.cell(_)` consumer (concat, first, next, take, …) to
  # rediscover and crash on. Only the HEAD is normalized; the tail stays
  # lazy, so an infinite seq still realizes one cell at a time.
  defp realize_loop(%__MODULE__{} = l, depth) do
    if depth > 100_000 do
      raise "LazySeq.realize: thunk chain #{depth} deep without a head — " <>
              "a self-referential lazy seq never produces a cell; it would hang forever"
    end

    case force(l) do
      [] -> nil
      %BeamLisp.Vector{} = v -> normalize_cell(BeamLisp.Vector.to_list(v))
      %BeamLisp.Set{} = s -> normalize_cell(BeamLisp.Set.to_list(s))
      %__MODULE__{} = nested -> realize_loop(nested, depth + 1)
      value -> value
    end
  end

  @doc """
  Normalize any seqable to a realized cell: `nil`, a `[head | tail]` list
  (whose tail may be a `LazySeq`), or, for non-seqables, the value itself.
  This is the one chokepoint every seq walk (forcing, `first`, `rest`,
  `take`, `count`, `Enum`) goes through.
  """
  def cell(nil), do: nil
  def cell([]), do: nil
  def cell(%__MODULE__{} = l), do: realize(l)
  def cell(xs) when is_list(xs), do: xs
  def cell(%BeamLisp.Vector{} = v), do: normalize_cell(BeamLisp.Vector.to_list(v))
  # A lazy-seq body may return any seqable — jank wraps a bare
  # collection in `(lazy-seq c1)` — so anything Enumerable becomes a
  # cell rather than falling through as an opaque value that the walk
  # loops then cannot match. Non-seqable values still pass through.
  def cell(%BeamLisp.Set{} = s), do: normalize_cell(BeamLisp.Set.to_list(s))

  # A string is seqable (elements are 1-char strings, matching `count`
  # and `subs`). Without this it fell through as an opaque value, and
  # `reduce` — which every `into` goes through — produced `[nil]` for
  # `(into [] "ab")`: no error, a plausible vector, and a nil surfacing
  # far from its cause.
  def cell(str) when is_binary(str), do: normalize_cell(String.graphemes(str))

  def cell(other) do
    # Reaching here means `other` is neither nil, a list, nor one of
    # our collection structs. If it is Enumerable (a range, a map,
    # a MapSet), treat it as a seq; otherwise pass it through.
    case Enumerable.impl_for(other) do
      nil -> other
      _ -> normalize_cell(Enum.to_list(other))
    end
  end

  defp normalize_cell([]), do: nil
  defp normalize_cell(xs), do: xs

  @doc "Fully realize into a proper list (iterative — a 100k `doall` cannot blow the stack)."
  def to_list(lazy), do: to_list_loop(cell(lazy), [])

  defp to_list_loop(nil, acc), do: Enum.reverse(acc)
  defp to_list_loop([h | t], acc), do: to_list_loop(cell(t), [h | acc])

  @doc "Realize up to `n` elements (iterative)."
  def prefix(lazy, n) when is_integer(n), do: prefix_loop(cell(lazy), n, [])

  defp prefix_loop(_cell, n, acc) when n <= 0, do: Enum.reverse(acc)
  defp prefix_loop(nil, _n, acc), do: Enum.reverse(acc)
  defp prefix_loop([h | t], n, acc), do: prefix_loop(cell(t), n - 1, [h | acc])

  @doc "`{taken, truncated?}`: sample up to `n` elements, flag if more remain."
  def sample(lazy, n) do
    taken = prefix(lazy, n + 1)

    case taken do
      xs when length(xs) > n -> {Enum.take(xs, n), true}
      xs -> {xs, false}
    end
  end

  @doc "Element count, forcing the whole seq (iterative)."
  def count(lazy), do: count_loop(cell(lazy), 0)

  defp count_loop(nil, acc), do: acc
  defp count_loop([_ | t], acc), do: count_loop(cell(t), acc + 1)

  @doc "Element at `i`, or `nil` (iterative)."
  def nth(lazy, i) when is_integer(i) and i >= 0, do: nth_loop(cell(lazy), i)

  defp nth_loop(nil, _i), do: nil
  defp nth_loop([h | _], 0), do: h
  defp nth_loop([_ | t], i), do: nth_loop(cell(t), i - 1)

  @doc "Force the whole seq for side effects, discarding elements."
  def run(lazy), do: run_loop(cell(lazy))

  defp run_loop(nil), do: :ok
  defp run_loop([_ | t]), do: run_loop(cell(t))

  defimpl Enumerable do
    def count(lazy), do: {:ok, BeamLisp.LazySeq.count(lazy)}

    def member?(_lazy, _x), do: {:error, __MODULE__}

    def reduce(lazy, acc, fun), do: do_reduce(acc, lazy, fun)

    defp do_reduce({:halt, acc}, _lazy, _fun), do: {:halted, acc}

    defp do_reduce({:suspend, acc}, lazy, fun),
      do: {:suspended, acc, &do_reduce(&1, lazy, fun)}

    defp do_reduce({:cont, acc}, lazy, fun) do
      case BeamLisp.LazySeq.cell(lazy) do
        nil ->
          {:done, acc}

        [h | t] ->
          case fun.(h, acc) do
            {:cont, acc} -> do_reduce({:cont, acc}, t, fun)
            {:halt, acc} -> {:halted, acc}
            {:suspend, acc} -> {:suspended, acc, &do_reduce(&1, t, fun)}
          end
      end
    end

    def slice(_lazy), do: {:error, __MODULE__}
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(lazy, opts) do
      limit = if is_integer(opts.limit) and opts.limit > 0, do: opts.limit, else: 20
      {elems, truncated} = BeamLisp.LazySeq.sample(lazy, limit)

      body = Enum.map(elems, &Inspect.inspect(&1, opts))
      body = Enum.intersperse(body, " ")
      # concat/1 wants a FLAT list of docs; a nested list is not a doc
      # and crashes the algebra formatter, which made a lazy seq
      # impossible to inspect — including inside a test failure message.
      body = if truncated, do: body ++ ["…"], else: body

      concat(["("] ++ body ++ [")"])
    end
  end
end
