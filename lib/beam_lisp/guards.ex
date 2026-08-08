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
end
