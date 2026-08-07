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

  Character literals `\\a` `\\newline` `\\space` `\\tab` `\\return`
  `\\backspace` `\\formfeed` `\\uNNNN` and `\\\\` read as **integer
  codepoints**, BEAM's native representation of a character (Elixir's `?a`
  is an integer too). `(str \\a)` therefore yields `"97"`, diverging from
  Clojure — closing that needs a runtime char wrapper, a later wave. The
  reader gap (a bare symbol `\\a`) is closed here; the value is a literal.

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

  @spec read_all(String.t()) :: [term]
  def read_all(source) when is_binary(source) do
    Process.put(@guard_cfg_key, atom_guard_config())
    Process.put(@guard_count_key, 0)
    Process.put(@fn_literal_depth_key, 0)

    case forms(String.to_charlist(source)) do
      {:ok, forms, rest} ->
        if blank?(rest) do
          forms
        else
          raise SyntaxError, message: "unexpected trailing input: #{inspect(rest)}"
        end

      {:error, message} ->
        raise SyntaxError, message: message
    end
  end

  @spec read_one(String.t()) :: term
  def read_one(source) do
    case read_all(source) do
      [form] -> form
      [] -> raise SyntaxError, message: "expected one form, got none"
      many -> raise SyntaxError, message: "expected one form, got #{length(many)}"
    end
  end

  # --- form parsing ---

  defp forms(rest), do: forms(skip_ignored(rest), [])

  defp forms(rest, acc) do
    case form(rest) do
      {:ok, f, rest} -> forms(skip_ignored(rest), [f | acc])
      :none -> {:ok, Enum.reverse(acc), rest}
      {:error, _} = err -> err
    end
  end

  defp form(rest) do
    case rest do
      [] -> :none
      [?( | rest] -> collection(rest, ?), &{:list, &1})
      [?[ | rest] -> collection(rest, ?], &{:vector, &1})
      [?{ | rest] -> map_form(rest)
      [?) | _] -> {:error, "unexpected )"}
      [?] | _] -> {:error, "unexpected ]"}
      [?} | _] -> {:error, "unexpected }"}
      [?' | rest] ->
        quote_form(rest, "quote")

      [?` | rest] ->
        quote_form(rest, "syntax-quote")

      [?~, ?@ | rest] ->
        quote_form(rest, "unquote-splicing")

      [?~ | rest] ->
        quote_form(rest, "unquote")

      [?@ | rest] ->
        wrap_form(rest, "@", "deref")

      [?#, ?( | rest] ->
        fn_literal(rest)

      [?#, ?{ | rest] ->
        # `#{a b}` is a set literal. It must be matched before the bare
        # `#` token path, and before `{`, since `#` alone is a legal
        # symbol character (trailing `#` is the auto-gensym marker).
        collection(rest, ?}, &{:set, &1})

      [?#, ?_ | rest] ->
        discard_form(rest)

      [?" | rest] -> string(rest, [])
      rest -> atom_form(rest)
    end
  end

  # `@x` reads as `(deref x)` — but the `@ → deref` mapping is not
  # wired into the reader: it lives in the reader-macro table (see
  # BeamLisp.RT.reader_macro/1), registered from priv/core.bl like a
  # Lisp reader macro, and rebindable. The builtin default keeps `@`
  # working before the prelude loads. `@` followed only by whitespace
  # (or nothing) is a reader error.
  defp wrap_form(rest, char, default) do
    name =
      case BeamLisp.RT.reader_macro(char) do
        {:ok, registered} -> registered
        :error -> default
      end

    case form(skip_ignored(rest)) do
      {:ok, f, rest} -> {:ok, {:list, [{:symbol, name}, f]}, rest}
      :none -> {:error, "#{char} with no following form"}
      err -> err
    end
  end

  defp quote_form(rest, name) do
    case form(skip_ignored(rest)) do
      {:ok, f, rest} -> {:ok, {:list, [{:symbol, name}, f]}, rest}
      :none -> {:error, "#{name} with no following form"}
      err -> err
    end
  end

  # `#(...)` fn literal: read the body, then desugar into the existing
  # `(fn [params] body)` form the compiler already handles — Clojure does
  # this as a reader macro too. A nested `#()` inside the body is an error,
  # tracked via a process-dict depth flag.
  defp fn_literal(rest) do
    if Process.get(@fn_literal_depth_key, 0) > 0 do
      {:error, "nested #() fn literals are not allowed"}
    else
      Process.put(@fn_literal_depth_key, 1)

      try do
        # The `(...)` after `#` is a single list and becomes the fn's one
        # body form: `#(+ % 1)` → `(fn [p1__] (+ p1__ 1))`.
        case collection(skip_ignored(rest), ?), &{:list, &1}) do
          {:ok, {:list, items}, rest} -> {:ok, desugar_fn(items), rest}
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
  defp discard_form(rest) do
    case form(skip_ignored(rest)) do
      {:ok, _discarded, rest} -> form(skip_ignored(rest))
      :none -> {:error, "#_ must be followed by a form"}
      err -> err
    end
  end

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

  defp collection(rest, closer, wrap) do
    case forms_until(skip_ignored(rest), closer, []) do
      {:ok, items, rest} -> {:ok, wrap.(items), rest}
      err -> err
    end
  end

  defp forms_until(rest, closer, acc) do
    case rest do
      [^closer | rest] -> {:ok, Enum.reverse(acc), rest}
      [] -> {:error, "unterminated collection, expected #{<<closer>>}"}
      rest ->
        case form(rest) do
          {:ok, f, rest} -> forms_until(skip_ignored(rest), closer, [f | acc])
          :none -> {:error, "unterminated collection, expected #{<<closer>>}"}
          err -> err
        end
    end
  end

  defp map_form(rest) do
    case forms_until(skip_ignored(rest), ?}, []) do
      {:ok, items, rest} ->
        if rem(length(items), 2) == 0 do
          {:ok, {:map, Enum.chunk_every(items, 2) |> Enum.map(&List.to_tuple/1)}, rest}
        else
          {:error, "map literal has an odd number of forms"}
        end

      err ->
        err
    end
  end

  defp string(rest, acc) do
    case rest do
      [] ->
        {:error, "unterminated string"}

      [?" | rest] ->
        {:ok, List.to_string(Enum.reverse(acc)), rest}

      [?\\, c | rest] ->
        string(rest, [unescape(c) | acc])

      [c | rest] ->
        string(rest, [c | acc])
    end
  end

  defp unescape(?n), do: ?\n
  defp unescape(?t), do: ?\t
  defp unescape(?r), do: ?\r
  defp unescape(c), do: c

  defp atom_form(rest) do
    {token, rest} = Enum.split_while(rest, fn c -> c not in @delimiters end)

    case token do
      [] -> {:error, "unexpected character #{inspect(hd(rest))}"}
      token -> atom_form(List.to_string(token), rest)
    end
  end

  defp atom_form(token, rest) do
    form = classify(token)
    check_atom_safety!(form, token)
    {:ok, form, rest}
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

  defp skip_ignored([?; | rest]), do: skip_ignored(Enum.drop_while(rest, &(&1 != ?\n)))
  defp skip_ignored([c | rest]) when c in [?\s, ?\t, ?\n, ?\r, ?,], do: skip_ignored(rest)
  defp skip_ignored(rest), do: rest

  defp blank?(rest), do: Enum.all?(rest, &(&1 in [?\s, ?\t, ?\n, ?\r]))
end
