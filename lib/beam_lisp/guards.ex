defmodule BeamLisp.Guards do
  @moduledoc """
  Guard-safe predicates that carry the "struct is a map" invariant.

  On the BEAM a struct IS a map: `is_map(%BeamLisp.Vector{})` is `true`,
  because a struct is a map carrying a `:__struct__` key. beam-lisp has
  eight struct kinds — `Vector`, `Set`, `LazySeq`, the references
  (`Atom`, `Volatile`, `Promise`, `Future`, `Reduced`), and user records —
  but its own map type is a *plain* map. A bare `is_map` guard therefore
  silently accepts every struct, so any clause that means "a beam-lisp
  map" must also exclude structs or it swallows them — safe only by
  clause order today: invisible at the call site, unenforced, and
  silently broken by anyone appending or reordering a clause.

  `defguard` is expanded at compile time, so `is_bl_map(x)` emits the
  exact guard an author would hand-write (`is_map(x) and not is_struct(x)`)
  — zero runtime cost; the win is that the name states the invariant.

  Historical symptoms of the bare-`is_map` bug (fixed by routing the
  collection clauses through these guards):

      (count (atom 1))            ; counted the struct's fields (2)
      (transientable? (atom 1))   ; true
      (coll? (atom 1))            ; true
      (get (atom 1) :value)       ; nil, indistinguishable from a miss

  The collection fns in `BeamLisp.RT` guard their plain-map clauses with
  `is_bl_map`, route records through `%{__struct__}` clauses (records are
  user-facing maps and keep working), and RAISE for the reference structs
  — they are not collections.
  """

  @doc """
  True for a beam-lisp map: a *plain* Elixir map, excluding every struct
  (a struct's `is_map` is true, so a bare `is_map` would swallow the
  other 8 struct kinds).
  """
  defguard is_bl_map(x) when is_map(x) and not is_struct(x)

  @doc """
  True for a beam-lisp *reference* struct — the types that hold a value
  behind an indirection (`Atom`, `Volatile`, `Promise`, `Future`) plus the
  `Reduced` reduce sentinel. None of them is a collection: collection fns
  must raise on them rather than treat a struct as a map.
  """
  defguard is_ref_type(x)
           when is_struct(x, BeamLisp.Atom) or is_struct(x, BeamLisp.Volatile) or
                  is_struct(x, BeamLisp.Promise) or is_struct(x, BeamLisp.Future) or
                  is_struct(x, BeamLisp.Reduced)

  # The tags that mark a tuple as language machinery rather than data.
  # Declared before the docs below so the `@doc` attribute lands on the
  # guard it describes (an attribute between a `@doc` and its definition
  # steals it, which Elixir warns about).
  # NOT here, deliberately:
  #   :bl_set / :bl_set_ack / :bl_deref / :bl_value — those are MESSAGES
  #   between a ref and its holder process (see refs.ex), never values a
  #   user holds. Excluding them would have made `(first (tuple :bl_set x))`
  #   — an ordinary, spellable data tuple — mysteriously opaque.
  @internal_tuple_tags [
    :"$blfn",
    :"$remote",
    :"$macro",
    :"$protocol",
    :"$transient",
    :symbol,
    :meta,
    :bl_deftype,
    :bl_reify,
    :bl_vec
  ]

  @doc "The tuple tags that mark a value as language machinery, not data."
  def internal_tuple_tags, do: @internal_tuple_tags

  @doc """
  True for an Erlang tuple that is *data* — a positional collection the
  user can read with `first`/`nth`/`count`/`seq` — as opposed to one of
  the language's own TAGGED values, which merely happen to be tuples.

  A tuple is genuinely positional on this VM, and beam-lisp's pattern
  layer already says so: `[p q]` matches an Erlang tuple and a beam-lisp
  vector alike. But the implementation also encodes several internal
  values as tagged tuples, and those must stay opaque:

      {:"$blfn", fixed, variadic}   a multi-arity fn
      {:"$remote", mod, fun}        a remote fn handle
      {:"$macro", fn}               a macro value
      {:"$protocol", …}             a protocol value
      {:"$transient", …}            a transient handle
      {:symbol, name}               a symbol
      {:meta, form, m}              a reader form carrying metadata — a macro
                                    receives these, so they ARE user-reachable
      {:bl_deftype, mod, fields}    a deftype instance (no map/seq semantics
                                    BY DESIGN — Clojure's deftype has none)
      {:bl_reify, ref, captures}    a reify instance (same reason)
      {:bl_vec, cnt, shift, …}      a vector's internal trie node

  Without this exclusion, making tuples positional would have quietly
  given every one of them a collection surface: `(count some-fn)` would
  answer 3, and a `deftype`'s or `reify`'s fields would become readable
  through `nth` — the exact encapsulation those forms exist to provide.

  The test is the leading element: every internal tag is an atom in a
  known set, and no user tuple can hold one, because those atoms are not
  spellable as beam-lisp keywords (`$blfn`) or are reserved names.

  **Adding a new tagged-tuple representation means adding it here.** The
  list is the single place that decides what is data and what is
  machinery; `@internal_tuple_tags` is public so a test can assert the
  two stay in step rather than discovering the omission as `(count
  some-value)` answering a field count.
  """
  defguard is_data_tuple(x)
           when is_tuple(x) and
                  (tuple_size(x) == 0 or
                     not (:erlang.is_atom(:erlang.element(1, x)) and
                            :erlang.element(1, x) in @internal_tuple_tags))
end
