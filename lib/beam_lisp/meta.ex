defmodule BeamLisp.Meta do
  @moduledoc """
  Clojure metadata on the BEAM.

  Metadata is an arbitrary map attached to a value, invisible to `=` and
  to printing, read back by `meta`, carried by `with-meta`/`vary-meta`.
  jank's `core.jank` head is built on it (`^{:doc …}`, `^:private`,
  `^:dynamic`), and the threading / `doto` macros thread
  `(meta form)` / `(with-meta form …)` for source-location info.

  The hard part is the BEAM's term model. Erlang terms are immutable and
  *value-typed*: equality is structural, so there is no per-value slot
  that `=` and `inspect` can be told to skip. Clojure gets metadata from
  an IObj slot on collections plus a header slot on vars — neither exists
  on a bare Erlang term. The only identity immutable terms actually have
  is structural equality, and using *that* as a metadata key would leak
  metadata across every structurally-identical term in the program.

  So this module implements the slice of the metadata layer that is
  honest on the BEAM, and no-ops the rest:

  ## Supported

  * **lazy seqs** — a `%BeamLisp.LazySeq{}` carries a unique `:key`
    reference (the same one that gates its memoized realization), which
    is a genuine per-instance identity. Metadata is keyed by it, so it
    is invisible to `=` (seq equality compares realized contents, never
    the struct) and to printing (the `Inspect` impl renders the body).
    `with_meta/2` returns a *fresh* node (new key, thunk re-forced) so
    the original keeps its own metadata and its realization cache.
  * **vars** — var metadata is real and lives in `BeamLisp.Env` under
    `{:meta, ns, name}`, the same key that already carried docstrings.
    `Env.put_meta/3` now takes a general map with merge semantics
    (`^:doc` and `^:private` coexist), and `Env.doc_string/2` still
    resolves it through the alias/refer/core rules.

  ## Deliberately not supported (with the reason)

  * **functions** — Erlang funs do have reference identity, so a side
    table keyed by the fun term *would* make `(meta f)` work. But
    `with-meta` must return a **new** value while the original keeps its
    own metadata, and a fun-term key has exactly one slot per term: the
    "new" value and the original are the same term and would share it.
    Wrapping the fun to get a distinct term would break `=` (a wrapper
    is a different term) and `BeamLisp.Link` direct calls. Clojure
    itself drops metadata on plain functions (they are not IObj), so
    dropping it here is faithful.
  * **numbers / strings / keywords / symbols / vectors / maps / lists /
    forms** — all value-typed. A structural key would collide across
    equal terms and never be collectable. `with_meta/2` on these is a
    no-op (returns the value unchanged) and `meta/1` returns `nil` —
    which is exactly enough for jank's threading / `doto` macros: they
    thread metadata purely for source-location info, and a `nil` meta
    round-trips through `with-meta` cleanly without changing the shape
    of the threaded form.

  ## Boundedness

  A value-metadata entry lives in the shared vars ETS table for the
  process lifetime. Entries are keyed by fresh references, so the table
  only grows by the number of *distinct* `with_meta` calls on lazy seqs,
  never by re-traversals — the same trade-off the lazy-seq realization
  cache already documents.
  """

  @table :beam_lisp_vars

  @doc """
  The metadata map attached to `x`, or `nil` when it has none.

  Returns `nil` for every value type that cannot carry metadata
  (see the module doc), so the Clojure idiom `(meta x)` is always safe.
  """
  def meta(%BeamLisp.LazySeq{} = lazy) do
    case :ets.lookup(@table, meta_key(lazy)) do
      [{_, m}] -> m
      [] -> nil
    end
  end

  def meta(_other), do: nil

  @doc """
  Attach `m` (a map) to `x`, returning a value equal to `x` that
  carries it. `nil` clears metadata (and is a no-op for types that
  cannot carry it). A non-map, non-nil `m` is an error, matching
  Clojure's "Metadata must be … a Map".

  On a lazy seq the returned value is a **fresh node**: a new identity
  key and a re-forced thunk, so the original keeps its own metadata and
  its realization cache untouched. On every other type `x` is returned
  unchanged.
  """
  def with_meta(%BeamLisp.LazySeq{} = lazy, nil) do
    # nil metadata clears: return a fresh node (new identity, no entry)
    # so the original's metadata and realization cache are untouched.
    %BeamLisp.LazySeq{lazy | key: make_ref()}
  end

  def with_meta(%BeamLisp.LazySeq{} = lazy, m) when is_map(m) do
    fresh = %BeamLisp.LazySeq{lazy | key: make_ref()}
    :ets.insert(@table, {meta_key(fresh), m})
    fresh
  end

  def with_meta(x, nil), do: x
  def with_meta(x, m) when is_map(m), do: x

  def with_meta(_x, m),
    do: raise(ArgumentError, "metadata must be a map or nil, got: #{inspect(m)}")

  @doc """
  `(vary-meta x f)`: reattach `(f (meta x))` to `x`. `f` is a beam-lisp
  fn value or a bare Elixir function; it always receives the current
  metadata map (or `nil` when absent), like Clojure.
  """
  def vary_meta(x, f) when is_function(f) do
    with_meta(x, f.(meta(x)))
  end

  def vary_meta(x, f) do
    with_meta(x, BeamLisp.RT.invoke(f, [meta(x)]))
  end

  # The ETS key for a value's metadata. Lazy seqs key on their identity
  # reference; the tag keeps this disjoint from the env's `{:meta, ns, name}`
  # var-metadata key and from the `{:lazy, ref}` realization cache.
  defp meta_key(%BeamLisp.LazySeq{key: key}), do: {:meta_of, key}
end
