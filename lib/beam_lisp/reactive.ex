defmodule BeamLisp.Derived do
  @moduledoc """
  A `derived` value: a computation over other references (atoms or other
  deriveds) that recomputes, lazily, only when one of those references has
  actually changed.

  Backed by a memo cell holding either `:stale` or `{:fresh, value,
  recorded_dep_values}`. A derived is pull-based: changing a dependency costs
  nothing, and the recompute happens on the next `deref`. This is Clojure's
  reaction/lens shape on the BEAM, with no push and no glitch-freedom promise.
  """
  defstruct [:cell, :deps, :thunk]
end

defmodule BeamLisp.Reactive do
  @moduledoc """
  `derived` / `derived?`, over the memo cell and the atoms of W3.

  Incremental computation without a reverse-dependency graph: a derived
  remembers the exact dependency values it last computed from. On `deref` it
  reads the dependencies' CURRENT values and recomputes only if one differs.
  Because reading a derived dependency recurses, staleness propagates through a
  chain of deriveds on demand. `swap!` on an atom pays nothing for this — the
  cost is on the derived's `deref`, where it belongs.
  """
  alias BeamLisp.{Derived, LazyMemo}

  @doc """
  Build a derived over `deps` (a list of atoms and/or deriveds) and a zero-arg
  `thunk` that reads them. The thunk runs on the first `deref` and again only
  after a dependency's value changes.
  """
  def derive(deps, thunk) when is_function(thunk, 0) do
    # `deps` arrives as a bl vector from the `derived` macro, or a plain list
    # from Elixir. Normalize to a list of ref structs.
    dep_list =
      case deps do
        %BeamLisp.Vector{} = v -> BeamLisp.Vector.to_list(v)
        list when is_list(list) -> list
      end

    %Derived{cell: LazyMemo.create_ref(:stale), deps: dep_list, thunk: thunk}
  end

  @doc "Current value of a derived, recomputing iff a dependency changed."
  def deref(%Derived{} = d), do: value(d)

  @doc "True for a derived."
  def derived?(%Derived{}), do: true
  def derived?(_), do: false

  defp value(%Derived{cell: cell, deps: deps, thunk: thunk} = d) do
    current = Enum.map(deps, &dep_value/1)

    case LazyMemo.read(cell) do
      {:fresh, v, recorded} when recorded == current ->
        v

      other ->
        nv = BeamLisp.RT.invoke(thunk, [])

        case LazyMemo.exchange_ref(cell, other, {:fresh, nv, current}) do
          :ok -> nv
          # A concurrent writer moved the cell; re-evaluate freshness. The
          # thunk is assumed pure, so converging on a recomputed value is safe.
          :retry -> value(d)
          :cycle -> nv
        end
    end
  end

  # Reading a dependency. A derived dep recurses (bringing it current and
  # yielding its up-to-date value); an atom reads its value cell; anything else
  # is treated as a constant dependency and returned as-is.
  defp dep_value(%Derived{} = d), do: value(d)
  defp dep_value(%BeamLisp.Atom{} = a), do: BeamLisp.Refs.deref(a)
  defp dep_value(other), do: other
end
