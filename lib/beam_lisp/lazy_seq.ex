defmodule BeamLisp.LazySeq do
  @moduledoc """
  A lazily-realized sequence — the Clojure seq model, native on the BEAM.

  A `LazySeq` holds a zero-arity thunk. Forcing it produces either `nil`
  (empty) or a `[head | tail]` cell whose `tail` is itself a `LazySeq` or a
  realized list, so a lazy seq is a chain of deferred cells that each realize
  exactly when they are reached.

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

  @table :beam_lisp_vars

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

  @doc "Run a node's thunk exactly once, caching and returning the result."
  def force(%__MODULE__{key: key, thunk: thunk}) do
    case :ets.lookup(@table, {:lazy, key}) do
      [{_, value}] ->
        value

      [] ->
        value = thunk.()
        :ets.insert(@table, {{:lazy, key}, value})
        value
    end
  end

  @doc "Force a node and normalize an empty list to `nil` (a realized cell)."
  def realize(%__MODULE__{} = l) do
    case force(l) do
      [] -> nil
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
  def cell(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  def cell(other), do: other

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
