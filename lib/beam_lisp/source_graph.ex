defmodule BeamLisp.SourceGraph do
  @moduledoc """
  Env-independent `(ns …)` header parsing and require-closure hashing — the
  single source of truth for AOT freshness (FEAT-030).

  The AOT invalidation key is two-tier:

    * a coarse TOOLCHAIN key (`BeamLisp.AOTCache.compiler_key/0`) that hashes
      the self-hosted compiler, the reader providers, and the ambient prelude
      (`core`/`sugar`) — anything whose change can alter EVERY emitted byte, so
      a change there invalidates all beams; and
    * a fine PER-NAMESPACE key (`closure_hash/3` here) over a namespace and its
      transitive explicit `:require` closure only. Editing one leaf namespace
      moves only its own key and its dependents', so `mix compile.beam_lisp`
      rebuilds that closure instead of all 100+ sources.

  Both tiers, and the runtime drift gate that must agree with them, route
  through the ONE `closure_hash/3` here. Identical inputs ⇒ identical hash,
  which is what keeps the build's manifest, the beam's provenance stamp, and
  the runtime's `stale?/2` in lockstep: a mismatch would make the runtime
  reject every beam and recompile from source on each boot.

  Everything here is pure text: no reader, no `BeamLisp.Env`, no running
  application. `compiler_key/0` is called from `BeamLisp.Bootstrap.install!/1`
  BEFORE `BeamLisp.init/0`, where the reader's ETS tables and the `Env`
  GenServer do not yet exist — so header parsing MUST NOT depend on them.
  """

  @doc """
  Parse a source's leading `(ns NAME …)` form into `{ns, requires}`.

  `ns` is the declared namespace name (`nil` if the file has no `ns` form —
  such a file compiles into `user`). `requires` is the list of namespace names
  named by the form's `:require` clauses, in appearance order, deduplicated.

  Pure and comment-aware: line comments (`;` … EOL, honouring string literals)
  are stripped first, so a `:require` mentioned inside a comment is never read
  as an edge — the exact trap that makes a naive regex report phantom
  dependencies. Only the FIRST symbol of each `:require` spec vector is taken,
  so `[a :refer [x y]]` contributes `a`, never `x`/`y`.
  """
  @spec header(binary) :: {binary | nil, [binary]}
  def header(content) when is_binary(content) do
    code = strip_comments(content)

    case Regex.run(~r/\(\s*ns\s+([^\s()\[\]{}]+)(.*)$/s, code, capture: :all_but_first) do
      nil ->
        {nil, []}

      [name, rest] ->
        form = balanced(rest)
        {name, requires(form)}
    end
  end

  @doc """
  Hash a namespace's require-closure.

  `srchash.(ns)` returns the content hash (or any stable per-source token) of a
  namespace's source, `nil` when unresolvable. `reqs.(ns)` returns that
  namespace's direct required namespaces. The result is a sha256 over the
  sorted `"<ns>:<srchash>"` line of every namespace in the transitive closure
  of `ns` (itself included), so it changes iff `ns` OR any namespace it
  transitively requires changes. Deterministic in the two callbacks alone —
  identical callbacks in build and runtime yield identical hashes.

  An unresolvable member (`srchash` → `nil`) contributes a `"<ns>:?"` sentinel
  rather than vanishing, so a require that stops resolving is itself a change.
  """
  @spec closure_hash(binary, (binary -> binary | nil), (binary -> [binary])) :: binary
  def closure_hash(ns, srchash, reqs)
      when is_binary(ns) and is_function(srchash, 1) and is_function(reqs, 1) do
    closure = closure(ns, reqs)

    closure
    |> Enum.sort()
    |> Enum.map(fn n -> "#{n}:#{srchash.(n) || "?"}" end)
    |> hash_lines()
  end

  @doc """
  Transitive require-closure of `ns` (including `ns`), using `reqs.(ns)` for the
  direct edges. Cycle-safe.
  """
  @spec closure(binary, (binary -> [binary])) :: MapSet.t()
  def closure(ns, reqs) when is_binary(ns) and is_function(reqs, 1) do
    walk([ns], reqs, MapSet.new())
  end

  @doc """
  sha256 (hex) over `lines` joined by a NUL separator — the shared digest for
  closure hashes and the toolchain key, so both tiers hash the same way.
  """
  @spec hash_lines([iodata]) :: binary
  def hash_lines(lines) do
    :crypto.hash(:sha256, IO.iodata_to_binary(Enum.intersperse(lines, 0)))
    |> Base.encode16(case: :lower)
  end

  # --- internals ---

  defp walk([], _reqs, seen), do: seen

  defp walk([ns | rest], reqs, seen) do
    if MapSet.member?(seen, ns) do
      walk(rest, reqs, seen)
    else
      walk(reqs.(ns) ++ rest, reqs, MapSet.put(seen, ns))
    end
  end

  # Strip `;` line comments, but never a `;` inside a "…" string literal. Char
  # literals (`\;`) are irrelevant inside an ns form and left as-is.
  defp strip_comments(content) do
    content
    |> String.split("\n")
    |> Enum.map(&strip_line/1)
    |> Enum.join("\n")
  end

  defp strip_line(line), do: strip_line(line, false, [])

  defp strip_line(<<>>, _in_str, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip_line(<<?\\, c, rest::binary>>, in_str, acc),
    do: strip_line(rest, in_str, [c, ?\\ | acc])

  defp strip_line(<<?", rest::binary>>, in_str, acc),
    do: strip_line(rest, not in_str, [?" | acc])

  defp strip_line(<<?;, _rest::binary>>, false, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip_line(<<c, rest::binary>>, in_str, acc),
    do: strip_line(rest, in_str, [c | acc])

  # Take the substring of `rest` up to and including the paren that closes the
  # `(ns` already consumed by the caller (depth starts at 1 for that open).
  defp balanced(rest), do: balanced(rest, 1, [])

  defp balanced(_s, 0, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp balanced(<<>>, _d, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp balanced(<<?", rest::binary>>, d, acc) do
    {str, rest2} = skip_string(rest, [?"])
    balanced(rest2, d, Enum.reverse(str) ++ acc)
  end

  defp balanced(<<?(, rest::binary>>, d, acc), do: balanced(rest, d + 1, [?( | acc])
  defp balanced(<<?), rest::binary>>, d, acc), do: balanced(rest, d - 1, [?) | acc])
  defp balanced(<<c, rest::binary>>, d, acc), do: balanced(rest, d, [c | acc])

  defp skip_string(<<>>, acc), do: {acc, <<>>}
  defp skip_string(<<?\\, c, rest::binary>>, acc), do: skip_string(rest, [c, ?\\ | acc])
  defp skip_string(<<?", rest::binary>>, acc), do: {[?" | acc], rest}
  defp skip_string(<<c, rest::binary>>, acc), do: skip_string(rest, [c | acc])

  # Namespace names named by the `:require` clauses of an ns form body. For each
  # `:require`, every top-level `[…]` spec contributes its first symbol; a bare
  # symbol spec contributes itself. Nested vectors (`:refer [x y]`) are skipped
  # by matching their brackets — only depth-1 spec heads count.
  defp requires(form) do
    form
    |> require_regions()
    |> Enum.flat_map(&spec_targets/1)
    |> Enum.uniq()
  end

  # Substrings that follow each `:require` keyword, up to the end of the form.
  # Good enough because an ns form's clauses are flat: whatever trails a
  # `:require` until the next clause keyword or the form end is its spec list.
  defp require_regions(form) do
    Regex.scan(~r/:require\b(.*?)(?=:require\b|:refer-clojure\b|:import\b|:use\b|$)/s, form,
      capture: :all_but_first
    )
    |> Enum.map(fn [region] -> region end)
  end

  # Targets in one `:require` region: the first symbol inside each depth-1
  # vector, plus any bare symbol spec at depth 0.
  defp spec_targets(region), do: spec_targets(region, 0, :seek, [])

  defp spec_targets(<<>>, _depth, _state, acc), do: Enum.reverse(acc)

  # Enter a vector.
  defp spec_targets(<<?[, rest::binary>>, depth, _state, acc) do
    state = if depth == 0, do: :head, else: :skip
    spec_targets(rest, depth + 1, state, acc)
  end

  defp spec_targets(<<?], rest::binary>>, depth, _state, acc),
    do: spec_targets(rest, max(depth - 1, 0), :seek, acc)

  # At the head of a depth-1 vector: read the first token as the target ns.
  defp spec_targets(<<c, _::binary>> = s, 1, :head, acc) when c not in [?\s, ?\t, ?\n, ?\r, ?,] do
    {tok, rest} = token(s)
    spec_targets(rest, 1, :skip, if(tok == "", do: acc, else: [tok | acc]))
  end

  # Bare symbol spec at depth 0 (e.g. `(:require foo bar)`): a symbol starting
  # char that is not a keyword/paren/bracket.
  defp spec_targets(<<c, _::binary>> = s, 0, :seek, acc)
       when c not in [?\s, ?\t, ?\n, ?\r, ?,, ?:, ?(, ?), ?[, ?], ?{, ?}] do
    {tok, rest} = token(s)
    spec_targets(rest, 0, :seek, if(tok == "", do: acc, else: [tok | acc]))
  end

  defp spec_targets(<<_, rest::binary>>, depth, state, acc),
    do: spec_targets(rest, depth, state, acc)

  defp token(s), do: token(s, [])
  defp token(<<>>, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<>>}

  defp token(<<c, _::binary>> = s, acc) when c in [?\s, ?\t, ?\n, ?\r, ?,, ?[, ?], ?(, ?), ?{, ?}],
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), s}

  defp token(<<c, rest::binary>>, acc), do: token(rest, [c | acc])
end
