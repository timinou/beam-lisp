defmodule BeamLisp.Reader.SyntaxError do
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
  `(unquote …)` and `~@` for `(unquote-splicing …)`. `;` starts a
  line comment and `,` is whitespace, same as in jank and Clojure.
  """

  alias BeamLisp.Reader.SyntaxError

  @delimiters [?\s, ?\t, ?\n, ?\r, ?,, ?(, ?), ?[, ?], ?{, ?}, ?", ?;]

  @spec read_all(String.t()) :: [term]
  def read_all(source) when is_binary(source) do
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

      [?" | rest] -> string(rest, [])
      rest -> atom_form(rest)
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
      token -> {:ok, classify(List.to_string(token)), rest}
    end
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

  # --- trivia ---

  defp skip_ignored([?; | rest]), do: skip_ignored(Enum.drop_while(rest, &(&1 != ?\n)))
  defp skip_ignored([c | rest]) when c in [?\s, ?\t, ?\n, ?\r, ?,], do: skip_ignored(rest)
  defp skip_ignored(rest), do: rest

  defp blank?(rest), do: Enum.all?(rest, &(&1 in [?\s, ?\t, ?\n, ?\r]))
end
