defmodule BeamLisp.SourceGraph do
  @moduledoc """
  The namespace graph, delegated to the language: `priv/boot/source-graph.bl`.

  Every freshness question the build asks — a file's declared ns and requires,
  a namespace's transitive closure, the closure hash the manifest stores and
  the runtime drift gate compares — is answered by ONE implementation, written
  in beam-lisp and AOT-compiled to `BeamLisp.Ns.SourceGraph`. This module
  is the Elixir call surface for it, nothing more: the same cutover seam shape
  as `BeamLisp.Compiler.compile/2` → `BeamLisp.Ns.Compiler`.

  `header/1` reads with the real reader, so the build never carries a second
  parser that could disagree with the language about what a `:require` is.

  It lives in the `boot/` tier: the drift gate consults it on every AOT load,
  so a change to it must rotate every stamp — and the toolchain key hashes
  `priv/boot/` by directory (`BeamLisp.AOTCache`), needing no graph itself.
  Boot-tier beams are trusted by the loader without a drift check (see
  `BeamLisp.AOT.ensure_loaded/1`), which is also what keeps `stale?/2` from
  recursing into the very namespace it asks.
  """

  @ns "source-graph"

  @doc "Parse a source's leading `(ns …)` form into `{ns, requires}`."
  @spec header(binary) :: {binary | nil, [binary]}
  def header(content) when is_binary(content) do
    [ns, requires] = call(:header, [content]) |> Enum.to_list()
    {ns, Enum.to_list(requires)}
  end

  @doc "Transitive require-closure of `ns` (including `ns`). Cycle-safe."
  @spec closure(binary, (binary -> [binary])) :: MapSet.t()
  def closure(ns, reqs) when is_binary(ns) and is_function(reqs, 1) do
    call(:closure, [ns, reqs]) |> Enum.to_list() |> MapSet.new()
  end

  @doc """
  Hash a namespace's require-closure: sha256 over the sorted `"<ns>:<srchash>"`
  line of every member. `srchash.(ns)` → content hash or `nil`; `reqs.(ns)` →
  direct requires. Identical callbacks ⇒ identical hash, build or runtime.
  """
  @spec closure_hash(binary, (binary -> binary | nil), (binary -> [binary])) :: binary
  def closure_hash(ns, srchash, reqs)
      when is_binary(ns) and is_function(srchash, 1) and is_function(reqs, 1) do
    call(:"closure-hash", [ns, srchash, reqs])
  end

  @doc "sha256 (hex) over `lines` joined by NUL — the shared digest shape."
  @spec hash_lines([iodata]) :: binary
  def hash_lines(lines), do: call(:"hash-lines", [Enum.map(lines, &IO.iodata_to_binary/1)])

  defp call(fun, args) do
    # The runtime is the CALLER's contract: every caller (the compile task, the
    # drift gate, a booted app) runs after `BeamLisp.init/0`. This fn must not
    # call `init/0` itself — `init` loads `core` through the drift gate, and a
    # gate that asked the graph would re-enter a half-run `init` (seeded? is
    # still false) and seed forever. Boot-tier beams bypass the graph in
    # `AOT.stale?/2` for exactly this reason.
    BeamLisp.Loader.ensure_loaded(@ns)

    # Through the VAR TABLE, not a module call: when the namespace is AOT-built
    # the var is the linked beam function; on a fresh tree (the compile task's
    # first pass, before any `.bl` beam exists) `ensure_loaded/1` evaluates the
    # source and the var is the interned closure. Same answer either way, and
    # it is what lets the build's own graph be compiled by the build.
    BeamLisp.RT.invoke(BeamLisp.Env.fetch!(@ns, Atom.to_string(fun)), args)
  end
end
