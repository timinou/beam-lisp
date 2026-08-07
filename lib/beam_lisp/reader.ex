defmodule BeamLisp.Reader.SyntaxError do
  defexception [:message]
end

defmodule BeamLisp.Reader.AtomLimitError do
  defexception [:message]
end

defmodule BeamLisp.Reader do
  @moduledoc """
  Turns beam-lisp source text into forms.

  A form is one of:

    * `{:symbol, name}` — `foo`, `IO/puts`, `+`
    * `{:keyword, name}` — `:ok`
    * `{:list, [form]}` — `(f a b)`
    * `{:vector, [form]}` — `[1 2 3]`
    * `{:map, [{k, v}]}` — `{:a 1}`
    * literals — integers, floats, strings, `nil`, `true`, `false`

  `'` is sugar for `(quote …)`, "`" for `(syntax-quote …)`, `~` for
  `(unquote …)`, `~@` for `(unquote-splicing …)` — those four are
  structural, needed to read core.bl itself. `@` is sugar for
  `(deref …)` by default, but the mapping lives in the rebindable
  reader-macro table and is registered from core.bl (see
  BeamLisp.RT.reader_macro!/2). `;` starts a line comment and `,`
  is whitespace, same as in jank and Clojure.

  The dispatch `#` prefixes a small set of reader macros, all of which
  desugar into ordinary forms here — the compiler never sees them.

    * `#(...)` — fn literal. `#(+ % 1)` reads as `(fn [p1__] (+ p1__ 1))`.
      `%` is `%1`, `%2`… are positional, `%&` is the rest arg. Arity is
      the highest `%N` used; no `%` at all gives a zero-arg fn. Nested
      `#()` is an error (as in Clojure). Generated params (`p1__`..`pN__`,
      `rest__`) are names a human would not write, so they cannot capture
      a user local the way `p1` might. `%` inside a nested plain `(fn …)`
      still belongs to the literal (Clojure's rule); unlike Clojure, which
      only rewrites `%` in list position, the walk here rewrites it inside
      every collection too, so `#(vector [% %])` works.
    * `#_ form` — discard: reads and drops the next form, so `(+ 1 #_2 3)`
      is `(+ 1 3)`. (A trailing `#_` with nothing after is an error.)
    * `#?(…)` / `#?@(…)` — reader conditional. `#?(:clj a :cljs b)`
      selects a branch by platform feature, `#?@` splices the selected
      collection's elements into the enclosing collection. beam-lisp
      answers to **`:clj`** (see the reader-conditionals section);
      `:default` matches last-resort, an unmatched conditional is a read
      error, and a top-level `#?@` is refused.
    * `^… form` — reader metadata. `^:kw form`, `^{:map} form`,
      `^Sym form` and `^"str" form` attach a metadata map to the
      following form (see `meta_form/2`).

  Character literals `\\a` `\\newline` `\\space` `\\tab` `\\return`
  `\\backspace` `\\formfeed` `\\uNNNN` and `\\\\` read as **integer
  codepoints**, BEAM's native representation of a character (Elixir's `?a`
  is an integer too). `(str \\a)` therefore yields `"97"`, diverging from
  Clojure — closing that needs a runtime char wrapper, a later wave. The
  reader gap (a bare symbol `\\a`) is closed here; the value is a literal.

  ## Source positions

  The parser threads a `{line, col, file}` position (both 1-indexed) as it
  consumes characters; newlines advance the line and reset the column. The
  position is attached to every form where an error could be reported —
  lists, vectors, maps, sets, symbols, and the head of each call form —
  via the `BeamLisp.FormMeta` `{:meta, form, %{line: l, col: c, file: f}}`
  wrapper, the source-location channel the compiler already strips before
  codegen. Scalars (integers, floats, strings, keywords) carry no wrapper
  because `FormMeta` only wraps form-shaped data. `read_string/1,2` is the
  position-aware entry and returns the wrapped forms; `read_all/1` and
  `read_one/1` deep-unwrap so the bare shapes they always returned are
  preserved for callers that ignore positions.

  ## Atom safety

  The reader interns nothing — symbol and keyword names travel as plain
  strings, and the compiler interns them into atoms downstream. But every
  source text passes through this module, so it is the natural trust
  boundary: it samples the VM-global atom table every
  `:beam_lisp, :atom_check_interval` symbol/keyword tokens (default 256) and
  raises `BeamLisp.Reader.AtomLimitError` once the table crosses
  `:beam_lisp, :atom_high_water_fraction` (default 0.9). A full atom table
  is not a catchable exception — interning one atom too many aborts the
  whole VM with a crash dump — so this turns a would-be VM abort into a
  clean, catchable read error. See `docs/trust-boundary.md` for the full
  trust model.
  """

  alias BeamLisp.Reader.AtomLimitError
  alias BeamLisp.Reader.SyntaxError

  @delimiters [?\s, ?\t, ?\n, ?\r, ?,, ?(, ?), ?[, ?], ?{, ?}, ?", ?;]

  @default_atom_high_water 0.9
  @default_atom_check_interval 256
  @guard_count_key {__MODULE__, :atom_guard_count}
  @guard_cfg_key {__MODULE__, :atom_guard_cfg}
  @fn_literal_depth_key {__MODULE__, :fn_literal_depth}

  @spec read_string(String.t()) :: [term]
  @spec read_string(String.t(), binary | nil) :: [term]
  def read_string(source, file \\ nil) when is_binary(source) do
    Process.put(@guard_cfg_key, atom_guard_config())
    Process.put(@guard_count_key, 0)
    Process.put(@fn_literal_depth_key, 0)

    case forms(String.to_charlist(source), {1, 1, file}) do
      {:ok, forms, rest, _pos} ->
        if blank?(rest) do
          forms
        else
          raise SyntaxError, message: "unexpected trailing input: #{inspect(rest)}"
        end

      {:error, message} ->
        raise SyntaxError, message: message
    end
  end

  @spec read_all(String.t()) :: [term]
  def read_all(source) when is_binary(source) do
    source |> read_string() |> Enum.map(&unwrap_deep/1)
  end

  @spec read_one(String.t()) :: term
  def read_one(source) do
    case read_all(source) do
      [form] -> form
      [] -> raise SyntaxError, message: "expected one form, got none"
      many -> raise SyntaxError, message: "expected one form, got #{length(many)}"
    end
  end

  # --- source positions ---
  #
  # `pos` is a `{line, col, file}` tuple (line and col 1-indexed, file a
  # path or nil). The parser threads it so each form knows where its first
  # character begins; with_pos/2 wraps a constructed form in the FormMeta
  # source-location channel, and unwrap_deep/1 removes every wrapper so
  # `read_all` keeps returning the bare shapes it always did.

  # Advance over one char: newline restarts the column at 1, anything else
  # advances the column by one. The file component is invariant.
  # The list clause must precede the `_char` catch-all so a charlist is
  # reduced over rather than treated as a single character.
  defp advance_pos(pos, chars) when is_list(chars), do: Enum.reduce(chars, pos, fn char, acc -> advance_pos(acc, char) end)
  defp advance_pos({line, _col, file}, ?\n), do: {line + 1, 1, file}
  defp advance_pos({line, col, file}, _char), do: {line, col + 1, file}

  # Attach the source location to a constructed form. FormMeta wraps only
  # form-shaped data, so this is a no-op for scalars — exactly the intent:
  # positions ride on the forms an error can name, never on a value.
  defp with_pos(form, {line, col, file}) do
    existing = BeamLisp.FormMeta.meta(form)
    BeamLisp.FormMeta.with_meta(form, Map.merge(existing || %{}, %{line: line, col: col, file: file}))
  end

  # Wrap the bare form a collection constructor produced, or pass an error
  # through untouched. `pos` is the position of the opening delimiter.
  defp with_pos_ok({:ok, form, rest, pos}, pos0), do: {:ok, with_pos(form, pos0), rest, pos}
  defp with_pos_ok(err, _pos0), do: err

  # Strip every `{:meta, form, m}` wrapper (top-level and nested) so a
  # position-free caller sees the bare form shapes it always matched on.
  defp unwrap_deep({:meta, form, _m}), do: unwrap_deep(form)
  defp unwrap_deep({:list, items}), do: {:list, Enum.map(items, &unwrap_deep/1)}
  defp unwrap_deep({:vector, items}), do: {:vector, Enum.map(items, &unwrap_deep/1)}
  defp unwrap_deep({:map, kvs}), do: {:map, Enum.map(kvs, fn {k, v} -> {unwrap_deep(k), unwrap_deep(v)} end)}
  defp unwrap_deep({:record, name, kvs}),
    do: {:record, name, Enum.map(kvs, fn {k, v} -> {unwrap_deep(k), unwrap_deep(v)} end)}
  defp unwrap_deep({:set, items}), do: {:set, Enum.map(items, &unwrap_deep/1)}
  defp unwrap_deep(other), do: other

  # --- form parsing ---

  defp forms(rest, pos) do
    {rest, pos} = skip_ignored(rest, pos)
    forms(rest, pos, [])
  end

  defp forms(rest, pos, acc) do
    case form(rest, pos) do
      # A `#?@` splice at the top level has no enclosing collection to
      # splice into; Clojure refuses it the same way.
      {:ok, {:splice, _items}, _rest, _pos} ->
        {:error, "reader conditional splicing (#?@) is only allowed inside a collection"}

      {:ok, f, rest, pos} ->
        {rest, pos} = skip_ignored(rest, pos)
        forms(rest, pos, [f | acc])

      :none -> {:ok, Enum.reverse(acc), rest, pos}
      {:error, _} = err -> err
    end
  end

  # Read one form. `pos` is the position of the head of `rest` — the
  # position where the form's first character sits — and is attached to
  # the form via its FormMeta wrapper. Scalars and keywords stay bare.
  defp form(rest, pos) do
    case rest do
      [] -> :none
      [?( | rest] -> with_pos_ok(collection(rest, advance_pos(pos, ?(), ?), &{:list, &1}), pos)
      # Only lists carry a position. A vector, map or set is as often a
      # *shape token* as a value — a parameter list, a `let` binding vector,
      # a destructuring pattern — and the compiler matches those structurally
      # in dozens of helpers. A list is where evaluation happens, so a list
      # is what an error names.
      [?[ | rest] -> collection(rest, advance_pos(pos, ?[), ?], &{:vector, &1})
      [?{ | rest] -> map_form(rest, advance_pos(pos, ?{))
      [?) | _] -> {:error, "unexpected )"}
      [?] | _] -> {:error, "unexpected ]"}
      [?} | _] -> {:error, "unexpected }"}
      [?' | rest] -> quote_form(rest, pos, "quote")
      [?` | rest] -> quote_form(rest, pos, "syntax-quote")
      [?~, ?@ | rest] -> quote_form(rest, pos, "unquote-splicing")
      [?~ | rest] -> quote_form(rest, pos, "unquote")
      [?@ | rest] -> wrap_form(rest, pos, "@", "deref")
      [?#, ?( | rest] -> fn_literal(rest, pos)
      [?#, ?{ | rest] ->
        # `#{a b}` is a set literal. It must be matched before the bare
        # `#` token path, and before `{`, since `#` alone is a legal
        # symbol character (trailing `#` is the auto-gensym marker).
        collection(rest, advance_pos(pos, [?#, ?{]), ?}, &{:set, &1})

      [?#, ?_ | rest] -> discard_form(rest, pos)
      # `#?` — the reader conditional (`#?(:clj … :cljs …)`), splicing
      # form `#?@(...)`. Must be matched before the bare-`#` path so a
      # conditional is never misread as a symbol (the silent mis-read that
      # shipped before wave 25 — a reader error is better than a wrong
      # form).
      [?#, ?? | rest] -> reader_conditional(rest, pos)
      # `^:kw form` / `^{:doc ...} form` / `^Sym form` — the reader
      # metadata macro. `^` is not a delimiter, so without this clause it
      # would read `^:private` as a bare symbol; here it attaches metadata
      # to the form that follows (see meta_form/2).
      [?^ | rest] -> meta_form(rest, pos)
      # `#Name{...}` / `#ns/Name{...}` — a record literal. Matched after
      # the `#`-dispatch forms it must not steal (`#()`, `#{}`, `#_`); a
      # `#` followed by anything else falls to record_or_tag, which reads
      # a record literal when a `{` follows the name and otherwise treats
      # the whole token as a bare atom (the trailing-`#` auto-gensym path).
      [?# | rest] -> record_or_tag(rest, pos)
      [?" | rest] -> string(rest, advance_pos(pos, ?"), [])
      rest -> atom_form(rest, pos)
    end
  end

  # `@x` reads as `(deref x)` — but the `@ → deref` mapping is not
  # wired into the reader: it lives in the reader-macro table (see
  # BeamLisp.RT.reader_macro/1), registered from priv/core.bl like a
  # Lisp reader macro, and rebindable. The builtin default keeps `@`
  # working before the prelude loads. `@` followed only by whitespace
  # (or nothing) is a reader error.
  defp wrap_form(rest, pos0, char, default) do
    name =
      case BeamLisp.RT.reader_macro(char) do
        {:ok, registered} -> registered
        :error -> default
      end

    {rest, pos} = skip_ignored(rest, pos0)

    case form(rest, pos) do
      {:ok, f, rest, pos} -> {:ok, with_pos({:list, [{:symbol, name}, f]}, pos0), rest, pos}
      :none -> {:error, "#{char} with no following form"}
      err -> err
    end
  end

  defp quote_form(rest, pos0, name) do
    {rest, pos} = skip_ignored(rest, pos0)

    case form(rest, pos) do
      {:ok, f, rest, pos} -> {:ok, with_pos({:list, [{:symbol, name}, f]}, pos0), rest, pos}
      :none -> {:error, "#{name} with no following form"}
      err -> err
    end
  end

  # `#(...)` fn literal: read the body, then desugar into the existing
  # `(fn [params] body)` form the compiler already handles — Clojure does
  # this as a reader macro too. A nested `#()` inside the body is an error,
  # tracked via a process-dict depth flag.
  defp fn_literal(rest, pos0) do
    if Process.get(@fn_literal_depth_key, 0) > 0 do
      {:error, "nested #() fn literals are not allowed"}
    else
      Process.put(@fn_literal_depth_key, 1)

      try do
        # The `(...)` after `#` is a single list and becomes the fn's one
        # body form: `#(+ % 1)` → `(fn [p1__] (+ p1__ 1))`.
        {rest, pos} = skip_ignored(rest, pos0)

        case collection(rest, pos, ?), &{:list, &1}) do
          {:ok, {:list, items}, rest, pos} -> {:ok, with_pos(desugar_fn(items), pos0), rest, pos}
          err -> err
        end
      after
        Process.put(@fn_literal_depth_key, 0)
      end
    end
  end

  # `#_ form` reads and drops the next form, then continues reading from
  # after it — so `#_` behaves like whitespace that happens to consume a
  # form: `(+ 1 #_2 3)` is `(+ 1 3)`. A trailing `#_` is an error.
  defp discard_form(rest, pos) do
    {rest, pos} = skip_ignored(rest, pos)

    case form(rest, pos) do
      {:ok, _discarded, rest, pos} ->
        {rest, pos} = skip_ignored(rest, pos)
        form(rest, pos)
      :none -> {:error, "#_ must be followed by a form"}
      err -> err
    end
  end

  # `^:kw form` / `^{:doc ...} form` / `^Sym form` / `^"str" form` — the
  # reader metadata macro. Reads a metadata spec, then the target form, and
  # attaches the spec as a metadata map on the target (see attach_meta/2).
  defp meta_form(rest, pos0) do
    {rest, pos} = skip_ignored(rest, pos0)

    case form(rest, pos) do
      {:ok, spec, rest, pos} ->
        {rest, pos} = skip_ignored(rest, pos)

        case form(rest, pos) do
          {:ok, target, rest, pos} -> {:ok, attach_meta(target, metadata_spec(spec)), rest, pos}
          :none -> {:error, "^ with no form to attach metadata to"}
          err -> err
        end

      :none ->
        {:error, "^ with no metadata (expected a Symbol, Keyword, String or Map)"}

      err ->
        err
    end
  end

  # Merge `^` metadata onto the target form. When the target already carries
  # a `{:meta, form, m}` wrapper — a list with a source position, or a
  # previous `^` in a stack like `^:private ^:static x` — the maps merge;
  # otherwise a fresh wrapper is created.
  #
  # This is the deliberate crossing of wave 20's "symbols stay bare" line:
  # positions attach to lists only because symbols are shape tokens matched
  # structurally in ~50 compiler sites. But `^` metadata is *written by the
  # author onto a specific form* — a def name, a fn param — so it only ever
  # wraps a form the author explicitly decorated, never every symbol. The
  # compiler peels the wrapper at compile/2 (positions) and name_of (names),
  # so a `^`-wrapped symbol costs nothing at the ~50 bare-symbol sites; the
  # ones that do see it are exactly the def/defn handlers that consume it.
  defp attach_meta({:meta, form, m}, meta_map), do: {:meta, form, Map.merge(m, meta_map)}
  defp attach_meta(form, meta_map), do: {:meta, form, meta_map}

  # The spec after `^` lowers to a metadata map with atom keys, the shape
  # FormMeta and the compiler's var-metadata writer both consume. `^:kw` is
  # `{:kw true}`; `^Sym`/`^"str"` are `{:tag …}`; `^{...}` is the map
  # itself (keys must be keywords, as in Clojure). Values stay reader forms
  # — the compiler lowers them when the metadata lands on a var.
  defp metadata_spec({:keyword, name}), do: %{String.to_atom(name) => true}
  defp metadata_spec({:symbol, name}), do: %{:tag => {:symbol, name}}
  defp metadata_spec(str) when is_binary(str), do: %{:tag => str}
  defp metadata_spec({:map, kvs}), do: Map.new(kvs, fn {k, v} -> {metadata_key(k), v} end)

  defp metadata_spec(other) do
    raise SyntaxError,
      message: "metadata must be a Symbol, Keyword, String or Map, got: #{inspect(other)}"
  end

  defp metadata_key({:keyword, name}), do: String.to_atom(name)

  defp metadata_key(other) do
    raise SyntaxError, message: "metadata map keys must be keywords, got: #{inspect(other)}"
  end

  # `#Name{...}` / `#ns/Name{...}` — a record literal. Read the type name
  # after the `#`; if a `{` follows it, read a map and lower to
  # `{:record, name, kvs}`. A `#` NOT followed by a record brace is just a
  # bare atom (`#foo` — the trailing-`#` auto-gensym marker is read as one
  # token), so any non-record read falls back to the whole-token atom path.
  defp record_or_tag(rest, pos0) do
    case atom_form(rest, pos0) do
      {:ok, {:symbol, name}, after_sym, _pos} ->
        case after_sym do
          [?{ | map_rest] ->
            case map_form(map_rest, pos0) do
              {:ok, {:map, kvs}, rest, pos} ->
                {:ok, with_pos({:record, name, kvs}, pos0), rest, pos}

              err ->
                err
            end

          _ ->
            atom_form([?# | rest], pos0)
        end

      _ ->
        atom_form([?# | rest], pos0)
    end
  end

  # --- reader conditionals ---
  #
  # `#?(:clj … :cljs …)` selects one branch by platform feature;
  # `#?@(:clj [a b] :default [c])` splices the selected collection's
  # elements into the enclosing collection. Both read the conditional
  # body as a flat `feat expr feat expr …` sequence and pick the first
  # match (see select_conditional/1); the splice then requires the chosen
  # branch to BE a collection and returns a `{:splice, items}` marker the
  # enclosing collection reader flattens.
  #
  # ## Which platform does beam-lisp answer to?
  #
  # `:clj`. Not `:bl`/`:beam` — honest, but no upstream file mentions
  # them, so every conditional would take the default branch, and most
  # `.cljc` conditionals have NO `:default`, which would turn the whole
  # file unreadable again. The point of supporting `#?` at all is to read
  # `.cljc` source (Specter is 139 conditionals across its modules), and
  # the JVM branch is the one closest to what beam-lisp implements, so it
  # is the branch that *can* run. The tradeoff is real: a `:clj` branch may
  # name a JVM-only var (`clojure.lang.PersistentQueue`) that beam-lisp
  # lacks, turning what would have been a clean read-failure into a runtime
  # failure. That is the honest cost of claiming the JVM branch, and
  # `:default` remains the escape hatch for source that must never take it.
  @conditional_feature :clj

  # `#?(...)` — select one branch and return its form as-is.
  defp reader_conditional([?( | rest], pos0) do
    {rest, pos} = skip_ignored(rest, pos0)

    case forms_until(rest, pos, ?), []) do
      {:ok, items, rest, pos} ->
        case select_conditional(items) do
          {:ok, form} -> {:ok, form, rest, pos}
          err -> err
        end

      err ->
        err
    end
  end

  # `#?@(...)` — select one branch and splice its elements in.
  defp reader_conditional([?@, ?( | rest], pos0) do
    {rest, pos} = skip_ignored(rest, pos0)

    case forms_until(rest, pos, ?), []) do
      {:ok, items, rest, pos} ->
        case select_conditional(items) do
          {:ok, form} -> splice_items(form, rest, pos)
          err -> err
        end

      err ->
        err
    end
  end

  defp reader_conditional(_, _pos0),
    do: {:error, "reader conditional must be #?( ... ) or #?@( ... )"}

  # Walk `feat expr feat expr …`. The first feature that matches wins;
  # `:default` matches last-resort. A feature that does not match skips its
  # expression. No match at all is an error (Clojure's behaviour) — a
  # silent empty read would hide a branch-selection bug.
  defp select_conditional([feat, expr | rest]) do
    case feature_match?(feat) do
      {:ok, true} -> {:ok, expr}
      {:ok, false} -> select_conditional(rest)
      {:error, _} = err -> err
    end
  end

  defp select_conditional([feat]) do
    case feature_match?(feat) do
      {:ok, _} -> {:error, "reader conditional feature #{inspect(feat)} has no expression"}
      {:error, _} = err -> err
    end
  end

  defp select_conditional([]),
    do: {:error, "reader conditional matched no feature and has no :default branch"}

  # `@conditional_feature` (our platform) and `:default` match; anything
  # else skips.
  defp feature_match?({:keyword, feat}), do: {:ok, feature_selected?(feat)}
  defp feature_match?(other), do: {:error, "reader conditional feature must be a keyword, got: #{inspect(other)}"}

  defp feature_selected?(feat),
    do: feat == Atom.to_string(@conditional_feature) or feat == "default"

  # A splice branch must be a collection; its elements become the marker.
  defp splice_items({:vector, items}, rest, pos), do: {:ok, {:splice, items}, rest, pos}
  defp splice_items({:list, items}, rest, pos), do: {:ok, {:splice, items}, rest, pos}
  defp splice_items({:set, items}, rest, pos), do: {:ok, {:splice, items}, rest, pos}

  defp splice_items(other, _rest, _pos),
    do: {:error, "reader conditional splicing requires a collection, got: #{inspect(other)}"}

  # Rewrite the `#(...)` body into a single-clause `(fn [params] body)`.
  # Params are p1__..pN__ (rest: rest__) — names with a marker a human
  # would not write, so they cannot capture a user local the way a plain
  # `p1` could. Arity is the highest positional `%N` used; `%` is `%1`.
  defp desugar_fn(items) do
    {body, {max_arg, has_rest}} = Enum.map_reduce(items, {0, false}, &rewrite_fn_arg/2)
    {:list, [{:symbol, "fn"}, fn_params(max_arg, has_rest), {:list, body}]}
  end

  # Deep rewrite: `%`/`%N`/`%&` are replaced inside every collection,
  # including a nested plain `(fn …)` — the literal's `%`s still belong to
  # the literal (Clojure's rule). Unlike Clojure, which only rewrites in
  # list position (a quirk that leaks raw `%` into vectors), this walk
  # covers vectors and maps too, so `#(vector [% %])` reads as intended.
  # Each item may already carry a position wrapper; it is preserved
  # through the rewrite so a rewritten `%` keeps pointing at its source.
  defp rewrite_fn_arg({:meta, form, m}, acc) do
    {rewritten, acc} = rewrite_fn_arg(form, acc)
    {{:meta, rewritten, m}, acc}
  end

  defp rewrite_fn_arg({:symbol, name}, {max_arg, has_rest}) do
    case fn_arg_index(name) do
      nil -> {{:symbol, name}, {max_arg, has_rest}}
      {:arg, n} -> {{:symbol, "p#{n}__"}, {max(max_arg, n), has_rest}}
      :rest -> {{:symbol, "rest__"}, {max_arg, true}}
    end
  end

  defp rewrite_fn_arg({:list, items}, acc) do
    rewrite_fn_children(items, &{:list, &1}, acc)
  end

  defp rewrite_fn_arg({:vector, items}, acc) do
    rewrite_fn_children(items, &{:vector, &1}, acc)
  end

  defp rewrite_fn_arg({:map, kvs}, acc) do
    flat = Enum.flat_map(kvs, &Tuple.to_list/1)
    {rewritten, acc} = Enum.map_reduce(flat, acc, &rewrite_fn_arg/2)
    kvs = Enum.chunk_every(rewritten, 2) |> Enum.map(&List.to_tuple/1)
    {{:map, kvs}, acc}
  end

  defp rewrite_fn_arg(other, acc), do: {other, acc}

  defp rewrite_fn_children(items, wrap, acc) do
    {rewritten, acc} = Enum.map_reduce(items, acc, &rewrite_fn_arg/2)
    {wrap.(rewritten), acc}
  end

  # Recognize a fn-literal arg token. `%` is `%1`; `%2`..`%N` are
  # positional; `%&` is the rest arg; anything else (e.g. `%foo`, `%0`) is
  # not an arg and is left untouched.
  defp fn_arg_index("%"), do: {:arg, 1}
  defp fn_arg_index("%&"), do: :rest
  defp fn_arg_index("%" <> digits) do
    case Integer.parse(digits) do
      {n, ""} when n >= 1 -> {:arg, n}
      _ -> nil
    end
  end
  defp fn_arg_index(_), do: nil

  defp fn_params(max_arg, has_rest) do
    positional = if max_arg >= 1, do: for(i <- 1..max_arg, do: {:symbol, "p#{i}__"}), else: []
    rest_elems = if has_rest, do: [{:symbol, "&"}, {:symbol, "rest__"}], else: []
    {:vector, positional ++ rest_elems}
  end

  # Read a bracketed collection to its closer; returns the bare constructed
  # form (`{:list, items}`, `{:vector, items}`, `{:set, items}`) — the
  # caller attaches the opening-delimiter position. `pos` is the position
  # of the first item's first character.
  defp collection(rest, pos, closer, wrap) do
    {rest, pos} = skip_ignored(rest, pos)

    case forms_until(rest, pos, closer, []) do
      {:ok, items, rest, pos} -> {:ok, wrap.(items), rest, pos}
      err -> err
    end
  end

  defp forms_until(rest, pos, closer, acc) do
    case rest do
      [^closer | rest] -> {:ok, Enum.reverse(acc), rest, advance_pos(pos, closer)}
      [] -> {:error, "unterminated collection, expected #{<<closer>>}"}
      rest ->
        case form(rest, pos) do
          # A `#?@` splice contributes its elements, not a marker node —
          # the acc is a prepending stack, so the splice items are
          # reversed before they join it.
          {:ok, {:splice, items}, rest, pos} ->
            {rest, pos} = skip_ignored(rest, pos)
            forms_until(rest, pos, closer, Enum.reverse(items) ++ acc)

          {:ok, f, rest, pos} ->
            {rest, pos} = skip_ignored(rest, pos)
            forms_until(rest, pos, closer, [f | acc])
          :none -> {:error, "unterminated collection, expected #{<<closer>>}"}
          err -> err
        end
    end
  end

  defp map_form(rest, pos) do
    {rest, pos} = skip_ignored(rest, pos)

    case forms_until(rest, pos, ?}, []) do
      {:ok, items, rest, pos} ->
        if rem(length(items), 2) == 0 do
          {:ok, {:map, Enum.chunk_every(items, 2) |> Enum.map(&List.to_tuple/1)}, rest, pos}
        else
          {:error, "map literal has an odd number of forms"}
        end

      err ->
        err
    end
  end

  defp string(rest, pos, acc) do
    case rest do
      [] ->
        {:error, "unterminated string"}

      [?" | rest] ->
        {:ok, List.to_string(Enum.reverse(acc)), rest, advance_pos(pos, ?")}

      [?\\, c | rest] ->
        string(rest, advance_pos(pos, [?\\, c]), [unescape(c) | acc])

      [c | rest] ->
        string(rest, advance_pos(pos, c), [c | acc])
    end
  end

  defp unescape(?n), do: ?\n
  defp unescape(?t), do: ?\t
  defp unescape(?r), do: ?\r
  defp unescape(c), do: c

  defp atom_form(rest, pos) do
    {token, rest} = Enum.split_while(rest, fn c -> c not in @delimiters end)

    case token do
      [] -> {:error, "unexpected character #{inspect(hd(rest))}"}
      token -> atom_form(List.to_string(token), rest, pos, advance_pos(pos, token))
    end
  end

  # `pos` is the position of the token's first character; `pos_after` is
  # the position of the following character (returned with the rest so the
  # next form is positioned correctly).
  #
  # Atoms deliberately do NOT carry a position. A symbol appears as a
  # *shape token* all over the compiler — a parameter, a binding name, a
  # `def` name, a destructuring pattern — and there are ~50 sites that
  # match `{:symbol, name}` structurally. Wrapping symbols would demand
  # meta-tolerance at every one of them, which is a large diff whose only
  # payoff is per-symbol columns nothing reports.
  #
  # The enclosing form already carries the line, and errors are reported
  # against forms: `(+ x nil)` names line 5, not the `nil` within it. So
  # positions ride on compound forms — lists, vectors, maps, sets — where
  # the compiler already destructures through a handful of choke points.
  defp atom_form(token, rest, _pos, pos_after) do
    form = classify(token)
    check_atom_safety!(form, token)
    {:ok, form, rest, pos_after}
  end

  defp classify("nil"), do: nil
  defp classify("true"), do: true
  defp classify("false"), do: false
  defp classify(":" <> name), do: {:keyword, name}

  # Character literals read as integer codepoints — BEAM's native
  # representation of a char (Elixir's `?a` is an integer too). The
  # str/print consequence is documented in the moduledoc.
  defp classify("\\newline"), do: ?\n
  defp classify("\\space"), do: ?\s
  defp classify("\\tab"), do: ?\t
  defp classify("\\return"), do: ?\r
  defp classify("\\backspace"), do: ?\b
  defp classify("\\formfeed"), do: ?\f
  defp classify("\\" <> rest) do
    case rest do
      "u" <> hex ->
        if hex =~ ~r/^[0-9a-fA-F]{4}$/ do
          String.to_integer(hex, 16)
        else
          raise SyntaxError, message: "invalid character literal: \\u#{hex}"
        end

      _ ->
        case String.to_charlist(rest) do
          [c] -> c
          _ -> raise SyntaxError, message: "invalid character literal: \\#{rest}"
        end
    end
  end

  defp classify(token) do
    case Integer.parse(token) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(token) do
          {float, ""} -> float
          _ -> {:symbol, token}
        end
    end
  end

  # --- atom-table guard ---
  #
  # The reader interns nothing; interning happens downstream in the
  # compiler, where a full BEAM atom table is a VM abort, not a catchable
  # exception. So guard the single choke point hostile input must pass:
  # sample the VM-global atom count every N symbol/keyword tokens and refuse
  # input once the table crosses the configured high-water mark. The count
  # lives in the process dictionary and is reset at every read, so it never
  # leaks between reads and concurrent readers don't interfere.

  defp check_atom_safety!({:symbol, _}, token), do: sample_atom_table!(token)
  defp check_atom_safety!({:keyword, _}, token), do: sample_atom_table!(token)
  defp check_atom_safety!(_literal, _token), do: :ok

  defp sample_atom_table!(token) do
    {fraction, interval} =
      Process.get(@guard_cfg_key, {@default_atom_high_water, @default_atom_check_interval})

    count = Process.get(@guard_count_key, 0) + 1
    Process.put(@guard_count_key, count)

    if rem(count, interval) == 0 do
      check_atom_table!(token, fraction)
    end
  end

  defp atom_guard_config, do: {high_water_fraction(), check_interval()}

  defp high_water_fraction do
    case Application.get_env(:beam_lisp, :atom_high_water_fraction, @default_atom_high_water) do
      f when is_number(f) -> min(max(f, 0.0), 1.0)
      _ -> @default_atom_high_water
    end
  end

  defp check_interval do
    case Application.get_env(:beam_lisp, :atom_check_interval, @default_atom_check_interval) do
      i when is_number(i) -> max(trunc(i), 1)
      _ -> @default_atom_check_interval
    end
  end

  defp check_atom_table!(token, fraction) do
    count = :erlang.system_info(:atom_count)
    limit = :erlang.system_info(:atom_limit)

    if count >= round(limit * fraction) do
      raise AtomLimitError,
        message:
          "refusing to read #{inspect(token)}: the VM atom table holds #{count} of #{limit} " <>
            "atoms, at or past the configured high-water fraction #{fraction}. Every unique " <>
            "symbol and keyword in .bl source interns a new atom, the table only grows, and a " <>
            "full table aborts the whole VM — so the reader stops here. Adjust " <>
            ":beam_lisp, :atom_high_water_fraction to change the ceiling."
    end
  end

  # --- trivia ---

  # Consume whitespace, commas, and `;` line comments, advancing the
  # position as characters are eaten so a form that follows them is
  # attributed to the line it actually sits on.
  defp skip_ignored(rest, pos) do
    case rest do
      [?; | rest] ->
        {comment, rest} = Enum.split_while(rest, &(&1 != ?\n))
        skip_ignored(rest, advance_pos(pos, comment))

      [c | rest] when c in [?\s, ?\t, ?\n, ?\r, ?,] ->
        skip_ignored(rest, advance_pos(pos, c))

      _ ->
        {rest, pos}
    end
  end

  defp blank?(rest), do: Enum.all?(rest, &(&1 in [?\s, ?\t, ?\n, ?\r]))
end
