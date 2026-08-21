defmodule BeamLisp.FormMeta do
  @moduledoc """
  Metadata on *form data* — the data a macro receives.

  `BeamLisp.Meta` handles runtime *values*, and is deliberately bounded:
  the BEAM's term model is value-typed, so only lazy seqs (which have a
  genuine per-instance identity reference) carry metadata, and
  `with_meta` no-ops on plain values. That is the honest answer for
  values, but wrong for **forms**: form data is compiler-controlled —
  it is an Elixir list / vector / map / `{:symbol, name}` produced by
  `Compiler.datum/1` and consumed by `Compiler.data_to_form/1` — so the
  compiler owns the whole lifecycle and metadata on forms is genuinely
  implementable.

  The mechanism is a `{:meta, form, m}` wrapper node, mirroring how the
  reader and compiler already tag symbols and keyword forms. `meta`/
  `with_meta` on a form datum wrap or unwrap it; the compiler strips the
  wrapper before codegen, so a form with metadata **compiles identically**
  to the same form without it — the metadata is source-location info that
  never reaches a runtime value. Because the strip happens in the
  compiler, `=` and printing of the *value* are never affected.

  This is what jank's threading macros and `doto` rely on: they build
  `(with-meta <new-form> (meta form))`, carrying source metadata from
  the input form to the output form through the macro data boundary.
  With no metadata attached (the common case, since the reader has no
  `^{}` syntax yet) `meta` returns `nil` and `with-meta` is a no-op, so
  the macros still thread correctly.
  """

  @doc """
  The metadata map attached to a form datum, or `nil` when it has none.

  `{:meta, form, m}` reads `m`; a lazy seq delegates to `BeamLisp.Meta`
  (the one runtime value type that carries metadata); everything else is
  `nil` — always safe, matching Clojure's `(meta x)`.
  """
  def meta({:meta, _form, m}), do: m
  def meta(%BeamLisp.LazySeq{} = lazy), do: BeamLisp.Meta.meta(lazy)
  # A vector carries metadata in a struct FIELD, so it stays a working
  # vector: wrapping one in `{:meta, …}` produced a value that `conj`,
  # `count`, `get` and `vector?` all failed on (BUG-009).
  def meta(%BeamLisp.Vector{meta: m}), do: m
  def meta(_form), do: nil

  @doc """
  Attach `m` (a map) to a form datum, returning a form that compiles
  identically and reads back via `meta`. `nil` clears (returns `form`
  unchanged).

  Form-shaped data — lists, vectors, maps, symbol tuples — wraps in
  `{:meta, form, m}`, which the compiler strips before codegen. Lazy
  seqs delegate to `BeamLisp.Meta` (real runtime metadata). Other values
  are returned unchanged (a documented no-op, matching `BeamLisp.Meta`).
  A non-map, non-nil `m` is an error, like Clojure's "Metadata must be a
  Map".
  """
  def with_meta(%BeamLisp.LazySeq{} = lazy, m), do: BeamLisp.Meta.with_meta(lazy, m)

  # A vector stores metadata in its own field rather than a wrapper node,
  # so it remains usable by every collection function.
  def with_meta(%BeamLisp.Vector{} = v, nil), do: %BeamLisp.Vector{v | meta: nil}

  # is_map-ok: `m` is the metadata map the caller attaches, never a
  # collection value — the same contract as the form clause below.
  def with_meta(%BeamLisp.Vector{} = v, m) when is_map(m),
    do: %BeamLisp.Vector{v | meta: m}

  # nil clears: unwrap a metadata-carrying form back to its bare form.
  def with_meta({:meta, form, _m}, nil), do: form
  def with_meta(form, nil), do: form
  # is_map-ok: m is the metadata map attached to a form (or the value
  # metadata case), never a collection value.
  def with_meta(form, m) when is_map(m), do: wrap(form, m)

  def with_meta(_form, m),
    do: raise(ArgumentError, "metadata must be a map or nil, got: #{inspect(m)}")

  @doc """
  `(vary-meta form f)`: reattach `(f (meta form))` to `form`. `f` is a
  beam-lisp fn value or a bare Elixir function; it always receives the
  current metadata map (or `nil` when absent).
  """
  def vary_meta(form, f) when is_function(f), do: with_meta(form, f.(meta(form)))
  def vary_meta(form, f), do: with_meta(form, BeamLisp.RT.invoke(f, [meta(form)]))

  # A map `m` wraps only form-shaped data; other values stay a no-op
  # (the documented value-metadata behavior, matching BeamLisp.Meta).
  defp wrap(form, m) do
    if form_shape?(form), do: {:meta, form, m}, else: form
  end

  # The datum shapes the compiler produces for forms, plus the tuple shapes
  # the reader emits before datum conversion (`{:list, items}` etc.) so
  # source positions attach at read time. A bare atom is ambiguous (keyword
  # datum vs `true`/`false`/`nil`), so keywords are not wrapped; form
  # metadata on a bare keyword is a rare edge.
  defp form_shape?({:symbol, _}), do: true
  defp form_shape?({:list, _}), do: true
  defp form_shape?({:vector, _}), do: true
  defp form_shape?({:map, _}), do: true
  defp form_shape?({:set, _}), do: true
  defp form_shape?(form) when is_list(form), do: true
  defp form_shape?(%BeamLisp.Vector{}), do: true
  # is_map-ok: form is a source datum (a plain map literal in the form
  # representation), and a struct form is still form-shaped — this decides
  # whether metadata attaches, not a collection operation.
  defp form_shape?(form) when is_map(form), do: true
  defp form_shape?(_), do: false
end
