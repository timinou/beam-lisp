defmodule BeamLisp.Set do
  @moduledoc """
  beam-lisp's set type: a Clojure set, backed by Elixir's `MapSet` for
  hash-based membership and structural sharing.

  **The struct-is-a-map hazard.** A struct IS a map on the BEAM, so every
  `when is_bl_map(...)` clause in the runtime excludes a set. The set
  clauses in `BeamLisp.RT` MUST precede the `is_bl_map` clauses (same rule
  as vectors and lazy seqs), or `count`/`seq`/`first` read the struct's
  fields instead of the members. `map?/1` already excludes structs, so a
  set correctly reports false for `map?` while staying a first-class
  collection.

  `\#{...}` set *literals* are a reader concern (reading `\#{}` is not yet
  wired) — this module is the type the reader/compiler would lower them
  to. Sets are built here via `new/1` and the `set` runtime fn.
  """

  defstruct [:members]

  @doc "The empty set."
  def new, do: %__MODULE__{members: MapSet.new()}

  @doc "A set of the distinct elements of `enum`."
  def new(enum), do: %__MODULE__{members: MapSet.new(enum)}

  @doc "Set with `x` added (idempotent)."
  # Metadata is invisible to `=`, so it must be invisible to set
  # membership too — otherwise a value and its metadata-bearing twin
  # both live in the set while comparing equal.
  def add(%__MODULE__{members: m} = s, x),
    do: %__MODULE__{s | members: MapSet.put(m, BeamLisp.RT.hash_key(x))}

  @doc "Set with `x` removed (idempotent)."
  def del(%__MODULE__{members: m} = s, x),
    do: %__MODULE__{s | members: MapSet.delete(m, BeamLisp.RT.hash_key(x))}

  @doc "Membership test."
  def member?(%__MODULE__{members: m}, x), do: MapSet.member?(m, BeamLisp.RT.hash_key(x))

  @doc "Cardinality."
  def count(%__MODULE__{members: m}), do: MapSet.size(m)

  @doc "The members as a list (iteration order is set-internal, as in Clojure)."
  def to_list(%__MODULE__{members: m}), do: MapSet.to_list(m)

  # Vectors implement Enumerable and sets did not, so every `Enum.*` /
  # `Stream.*` call on a set raised — including the one inside `to-list`,
  # whose own docstring promised sets were handled. Interop should work
  # in both directions for both collection types, not just one.
  defimpl Enumerable do
    def count(s), do: {:ok, BeamLisp.Set.count(s)}

    def member?(s, x), do: {:ok, BeamLisp.Set.member?(s, x)}

    def reduce(s, acc, fun), do: Enumerable.List.reduce(BeamLisp.Set.to_list(s), acc, fun)

    def slice(_s), do: {:error, __MODULE__}
  end
end
