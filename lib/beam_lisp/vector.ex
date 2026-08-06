defmodule BeamLisp.Vector do
  @moduledoc """
  The persistent vector: a 32-way bit-partitioned trie in Clojure's
  PersistentVector shape (`cnt`/`shift`/`root`/`tail`), whose tail buffer
  makes append amortized O(1) and indexed reads/writes O(log32 n).

  A vector small enough to fit the tail (≤ 32 elements) stores its elements
  directly as a tuple — which is also exactly the shape the compiler
  produces for vector literals, so `%Vector{items: {...}}` construction and
  receive-pattern matching keep working untouched. Larger vectors store the
  trie `{:bl_vec, cnt, shift, root, tail}`.

  Implements `Enumerable`, so vectors flow straight into Elixir's `Enum`
  and `Stream` — interop in both directions.
  """

  import Bitwise

  @trie_tag :bl_vec
  @leaf_mask 0x1f

  defstruct items: {}

  @type t :: %__MODULE__{items: tuple}

  # A trie only ever holds > 32 elements (≤ 32 lives in the tail tuple),
  # so requiring `cnt > 32` disambiguates the tag from an ordinary
  # 5-element vector that happens to start with the tag atom.
  defp trie?({@trie_tag, cnt, _shift, _root, _tail})
       when is_integer(cnt) and cnt > 32,
       do: true

  defp trie?(_), do: false

  defp empty_node(), do: List.to_tuple(List.duplicate(nil, 32))

  def new(items \\ []) when is_list(items) do
    if length(items) <= 32 do
      %__MODULE__{items: List.to_tuple(items)}
    else
      %__MODULE__{items: build_trie(items)}
    end
  end

  defp build_trie(items) do
    Enum.reduce(items, {@trie_tag, 0, 5, {}, {}}, &trie_conj(&2, &1))
  end

  def count(%__MODULE__{items: items}) do
    if trie?(items), do: elem(items, 1), else: tuple_size(items)
  end

  def nth(%__MODULE__{items: items}, i) when is_integer(i) and i >= 0 do
    if trie?(items) do
      if i < elem(items, 1), do: elem(array_for(items, i), i &&& @leaf_mask)
    else
      if i < tuple_size(items), do: elem(items, i)
    end
  end

  def nth(%__MODULE__{}, _i), do: nil

  def first(%__MODULE__{} = v), do: nth(v, 0)

  def rest(%__MODULE__{} = v), do: v |> to_list() |> tl_or_empty()

  defp tl_or_empty([_ | t]), do: t
  defp tl_or_empty([]), do: []

  @doc "Clojure `conj`: append, amortized O(1) via the tail buffer."
  def conj(%__MODULE__{items: items}, x), do: %__MODULE__{items: conj_items(items, x)}

  defp conj_items(items, x) do
    if trie?(items) do
      trie_conj(items, x)
    else
      if tuple_size(items) < 32 do
        Tuple.insert_at(items, tuple_size(items), x)
      else
        trie_conj(build_trie(Tuple.to_list(items)), x)
      end
    end
  end

  @doc "Clojure `assocN`: replace at `i`; `i == count` appends like `conj`."
  def assoc(%__MODULE__{items: items}, i, x) when is_integer(i) and i >= 0 do
    if trie?(items) do
      cnt = elem(items, 1)

      cond do
        i < cnt -> %__MODULE__{items: do_assoc(items, i, x)}
        i == cnt -> %__MODULE__{items: trie_conj(items, x)}
        true -> raise ArgumentError, "assoc index #{i} out of bounds (count #{cnt})"
      end
    else
      n = tuple_size(items)

      cond do
        i < n -> %__MODULE__{items: put_elem(items, i, x)}
        i == n -> %__MODULE__{items: conj_items(items, x)}
        true -> raise ArgumentError, "assoc index #{i} out of bounds (count #{n})"
      end
    end
  end

  def assoc(%__MODULE__{}, i, _x),
    do: raise(ArgumentError, "assoc index #{i} out of bounds")

  def drop(%__MODULE__{} = v, n), do: v |> to_list() |> Enum.drop(n)

  # --- trie internals -------------------------------------------------

  # The tuple holding element `i`: the tail for the last partial leaf,
  # otherwise the leaf reached by descending the index's 5-bit chunks.
  defp array_for({@trie_tag, cnt, shift, root, tail}, i) do
    if i >= cnt - tuple_size(tail) do
      tail
    else
      descend(root, shift, i)
    end
  end

  defp descend(node, 0, _i), do: node

  defp descend(node, level, i) do
    descend(elem(node, (i >>> level) &&& @leaf_mask), level - 5, i)
  end

  defp trie_conj({@trie_tag, cnt, shift, root, tail}, x) do
    tail_len = tuple_size(tail)

    if tail_len < 32 do
      {@trie_tag, cnt + 1, shift, root, Tuple.insert_at(tail, tail_len, x)}
    else
      {new_root, new_shift} = flush_tail(root, shift, cnt, tail)
      {@trie_tag, cnt + 1, new_shift, new_root, {x}}
    end
  end

  defp flush_tail(root, shift, cnt, tail) do
    if (cnt >>> 5) > (1 <<< shift) do
      new_root = empty_node() |> put_elem(0, root) |> put_elem(1, new_path(shift, tail))
      {new_root, shift + 5}
    else
      {push_tail(normalize_root(root), shift, cnt, tail), shift}
    end
  end

  defp normalize_root({}), do: empty_node()
  defp normalize_root(root), do: root

  defp push_tail(node, level, cnt, tail_node) do
    sub = ((cnt - 1) >>> level) &&& @leaf_mask

    if level == 5 do
      put_elem(node, sub, tail_node)
    else
      child = elem(node, sub)
      new_child =
        if is_nil(child),
          do: new_path(level - 5, tail_node),
          else: push_tail(child, level - 5, cnt, tail_node)

      put_elem(node, sub, new_child)
    end
  end

  defp new_path(0, node), do: node
  defp new_path(level, node), do: empty_node() |> put_elem(0, new_path(level - 5, node))

  defp do_assoc({@trie_tag, cnt, shift, root, tail}, i, x) do
    tailoff = cnt - tuple_size(tail)

    if i >= tailoff do
      {@trie_tag, cnt, shift, root, put_elem(tail, i - tailoff, x)}
    else
      {@trie_tag, cnt, shift, do_assoc_node(root, shift, i, x), tail}
    end
  end

  defp do_assoc_node(node, 0, i, x), do: put_elem(node, i &&& @leaf_mask, x)

  defp do_assoc_node(node, level, i, x) do
    sub = (i >>> level) &&& @leaf_mask
    put_elem(node, sub, do_assoc_node(elem(node, sub), level - 5, i, x))
  end

  # --- iteration ------------------------------------------------------

  def to_list(%__MODULE__{items: items}) do
    if trie?(items), do: trie_to_list(items), else: Tuple.to_list(items)
  end

  # Walk the leaves in order (a chunked descent — never nth-in-a-loop),
  # then append the tail. `depth` is the node levels from root to a leaf.
  defp trie_to_list({@trie_tag, _cnt, shift, root, tail}) do
    leaves_to_list(root, div(shift, 5)) ++ Tuple.to_list(tail)
  end

  defp leaves_to_list(node, 0), do: Tuple.to_list(node)

  defp leaves_to_list(node, depth) do
    Enum.flat_map(Tuple.to_list(node), fn child ->
      if is_nil(child), do: [], else: leaves_to_list(child, depth - 1)
    end)
  end

  defimpl Enumerable do
    def count(v), do: {:ok, BeamLisp.Vector.count(v)}

    def member?(v, x), do: {:ok, Enum.member?(BeamLisp.Vector.to_list(v), x)}

    def reduce(v, acc, fun), do: Enumerable.List.reduce(BeamLisp.Vector.to_list(v), acc, fun)

    def slice(_v), do: {:error, __MODULE__}
  end
end
