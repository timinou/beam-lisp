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

  @spec read_all(String.t()) :: [term]
  def read_all(source) when is_binary(source) do
    Process.put(@guard_cfg_key, atom_guard_config())
    Process.put(@guard_count_key, 0)

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
