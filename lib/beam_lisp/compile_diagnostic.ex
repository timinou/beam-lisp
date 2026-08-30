defmodule BeamLisp.CompileDiagnostic do
  @moduledoc """
  Turn a compiler failure into a diagnostic a human can act on — the file and
  line, the source line with a caret under the offending form, what the
  compiler was doing, the underlying cause, and a hint.

  ## Why this exists

  The compiler is itself a program (the reader/compiler pipeline, plus the
  self-hosted `.bl` compiler it delegates to). When it crashes on a *user's*
  form — a malformed `try`, a bad destructure, an arity slip — the raw failure
  is an Erlang `badarg` or an Elixir `FunctionClauseError` raised deep inside a
  compiler frame. On its own that reads as, literally:

      ** (ArgumentError) errors were found at the given arguments:
        * 1st argument: not a tuple

  which names nothing in the source that caused it. A user cannot fix what the
  message will not point at, and even the compiler's own maintainer has to
  reach for a stacktrace and bisect the file to find the form.

  This module closes that gap. Given the form being compiled (which carries its
  `{:meta, _, %{line, col, file}}` source position from the reader), the raw
  exception, and the stacktrace, it renders:

    * `file:line:col` — the exact location, clickable in an editor;
    * the source line, with a caret `^` column marker under the form;
    * "while compiling this <form-kind>" — the construct in play (a `try`, a
      `defn`, a call to `foo`), so the report names the shape, not an AST tuple;
    * the underlying cause in plain language (a `badarg` becomes "an internal
      compiler step got a value of the wrong shape", with the raw reason kept);
    * the deepest `.bl`/compiler frame, so a compiler bug is still locatable;
    * a hint when the failure shape is recognised.

  A known `BeamLisp.CompileError` (raised deliberately by `compile-error`) is
  ALREADY well-attributed — it is passed through untouched. This wrapper is for
  the *unexpected* crash, the one that used to be opaque.
  """

  @doc """
  Render a diagnostic string for a compiler failure on `form`.

  * `form` — the reader form being compiled, ideally `{:meta, inner, pos}`.
  * `exception` — the raised exception struct.
  * `stacktrace` — the `__STACKTRACE__` at the rescue site.
  * `opts` — `:file` (fallback when the form carries none), `:source` (the full
    source text, for the snippet — read from the file when absent), `:phase`
    (a short label like `"compiling"` / `"loading"`, default `"compiling"`).

  Returns a multi-line string. Never raises: any failure to build the rich
  report falls back to a plain `file:line: <message>`.
  """
  def render(form, exception, stacktrace, opts \\ []) do
    pos = position(form)
    file = pos[:file] || opts[:file]
    line = pos[:line]
    col = pos[:col]
    phase = opts[:phase] || "compiling"

    source = opts[:source] || read_source(file)

    [
      header(file, line, col),
      "",
      snippet(source, line, col),
      context_line(form, phase),
      cause_line(exception),
      frame_line(stacktrace),
      hint_line(exception, form)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  rescue
    # The renderer must never eclipse the error it describes. If anything here
    # trips, fall back to the plainest useful line.
    _ -> plain(form, exception, opts)
  end

  @doc """
  Wrap a compile action so any failure becomes a `BeamLisp.CompileError` whose
  message is the rich diagnostic. A `BeamLisp.CompileError` already carries
  position and passes through unchanged. Re-raises so the build still fails.

  `form` is the form being compiled; `opts` are forwarded to `render/4`.
  """
  def with_diagnostic(form, opts \\ [], fun) when is_function(fun, 0) do
    fun.()
  rescue
    # Already attributed — deliberate, well-worded compiler errors. Leave them.
    e in BeamLisp.CompileError ->
      reraise(e, __STACKTRACE__)

    # A RUNTIME beam-lisp error (a `(throw …)` or `(error …)` that actually
    # executed) is NOT a compile error — it is the program running. `eval_form`
    # both compiles AND evaluates the form, so a top-level `(throw :x)` reaches
    # here as a raised `ExInfo`. Pass it through untouched, or the diagnostic
    # would mislabel a genuine runtime raise as a compiler crash.
    e in BeamLisp.ExInfo ->
      reraise(e, __STACKTRACE__)

    e ->
      message = render(form, e, __STACKTRACE__, opts)
      pos = position(form)

      reraise(
        BeamLisp.CompileError.exception(
          message: message,
          file: pos[:file] || opts[:file],
          line: pos[:line],
          form: strip_meta(form)
        ),
        __STACKTRACE__
      )
  catch
    # A raw `throw` is control flow (beam-lisp's `(throw v)` lowers to an
    # Erlang throw). It is the program's value in flight, never a compiler
    # failure — re-throw it so `try`/`catch` in the source, and callers that
    # `catch_throw`, still see it.
    kind, value ->
      :erlang.raise(kind, value, __STACKTRACE__)
  end

  # ── position ──────────────────────────────────────────────────────

  # Pull {line, col, file} off the form's reader metadata. Only lists (and
  # collection literals) are wrapped, so a bare literal or a macro-built form
  # returns an empty position — the caller falls back to the file-level label.
  defp position({:meta, _inner, m}) when is_map(m) do
    [line: m[:line], col: m[:col], file: m[:file]]
  end

  defp position(_), do: []

  defp strip_meta({:meta, inner, _m}), do: strip_meta(inner)
  defp strip_meta(other), do: other

  # ── the pieces ────────────────────────────────────────────────────

  defp header(file, line, col) do
    loc =
      [file, line, col]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(":")

    if loc == "" do
      "beam-lisp compile error"
    else
      "beam-lisp compile error at #{loc}"
    end
  end

  # The source line with a caret under the form's column. A tab-aware caret
  # would need the terminal width; a space-padded caret is correct for the
  # common all-spaces indentation and close enough otherwise.
  defp snippet(nil, _line, _col), do: nil
  defp snippet(_source, nil, _col), do: nil

  defp snippet(source, line, col) do
    lines = String.split(source, "\n")

    case Enum.at(lines, line - 1) do
      nil ->
        nil

      text ->
        gutter = "#{line} | "
        pad = String.duplicate(" ", String.length(gutter))

        caret =
          case col do
            c when is_integer(c) and c > 0 ->
              pad <> String.duplicate(" ", c - 1) <> "^"

            _ ->
              nil
          end

        [gutter <> text, caret]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
        |> Kernel.<>("\n")
    end
  end

  # Name the construct in play, so the report says "while compiling this try
  # expression" instead of dumping an AST tuple.
  defp context_line(form, phase) do
    "  while #{phase} #{describe(form)}"
  end

  # A short, human name for the form's shape.
  defp describe(form) do
    case strip_meta(form) do
      {:list, [head | _]} ->
        case strip_meta(head) do
          {:symbol, name} -> "a `#{name}` form"
          _ -> "a list form"
        end

      {:list, []} ->
        "an empty list"

      {:symbol, name} ->
        "the symbol `#{name}`"

      {:vector, _} ->
        "a vector literal"

      {:map, _} ->
        "a map literal"

      {:set, _} ->
        "a set literal"

      other when is_binary(other) ->
        "a string literal"

      other when is_number(other) ->
        "a number literal"

      _ ->
        "this form"
    end
  end

  # The underlying cause, translated where the raw text is opaque.
  defp cause_line(exception) do
    "  cause: #{explain(exception)}"
  end

  # Turn a raw exception into a sentence. The two that dominate real compiler
  # crashes are a bare Erlang `badarg` (an internal step handed a value of the
  # wrong shape) and a `FunctionClauseError` (a form shape no clause matched);
  # both are meaningless on their own, so they get plain-language framing with
  # the raw reason kept for the maintainer.
  defp explain(%ArgumentError{message: msg}) do
    if String.contains?(msg, "not a tuple") or String.contains?(msg, "given arguments") do
      "an internal compiler step received a value of the wrong shape " <>
        "(#{first_line(msg)}). This usually means the form above is malformed " <>
        "in a way the compiler did not check for explicitly."
    else
      first_line(msg)
    end
  end

  defp explain(%FunctionClauseError{} = e) do
    "no compiler clause matched this form " <>
      "(#{first_line(Exception.message(e))}) — its shape is not one the " <>
      "compiler knows how to lower."
  end

  defp explain(%UndefinedFunctionError{} = e) do
    first_line(Exception.message(e))
  end

  defp explain(exception) do
    first_line(Exception.message(exception))
  end

  # The deepest frame that belongs to the compiler or a `.bl` source, so a
  # genuine compiler bug is still locatable. Elixir/Erlang stdlib frames are
  # skipped — they are never the cause, only the messenger.
  defp frame_line(stacktrace) when is_list(stacktrace) do
    frame =
      Enum.find(stacktrace, fn
        {mod, _fun, _arity, _loc} -> compiler_frame?(mod)
        _ -> false
      end)

    case frame do
      {mod, fun, arity, loc} ->
        where =
          case loc[:file] do
            nil -> ""
            f -> " (#{f}:#{loc[:line]})"
          end

        "  in: #{inspect(mod)}.#{fun}/#{arity_of(arity)}#{where}"

      _ ->
        nil
    end
  end

  defp frame_line(_), do: nil

  # A frame worth naming: the Elixir compiler modules, or a compiled `.bl`
  # namespace (the self-hosted compiler runs as `BeamLisp.Ns.*`).
  defp compiler_frame?(mod) do
    name = Atom.to_string(mod)

    String.starts_with?(name, "Elixir.BeamLisp.Ns.") or
      String.starts_with?(name, "Elixir.BeamLisp.Compiler") or
      String.starts_with?(name, "Elixir.BeamLisp.Reader") or
      String.starts_with?(name, "Elixir.BeamLisp.AOT")
  end

  defp arity_of(a) when is_integer(a), do: a
  defp arity_of(args) when is_list(args), do: length(args)

  # A hint tuned to the failure shape, when one is recognised.
  defp hint_line(%ArgumentError{message: msg}, form) do
    cond do
      String.contains?(msg, "not a tuple") and describes?(form, "try") ->
        "  hint: a `try` needs a body and at least one `catch` or `finally` " <>
          "clause. Check that each `(catch e …)` / `(finally …)` is well formed."

      String.contains?(msg, "not a tuple") ->
        "  hint: check the arguments of the form above — a missing or extra " <>
          "element often reaches an internal step as `nil`."

      true ->
        nil
    end
  end

  defp hint_line(_exception, _form), do: nil

  defp describes?(form, name) do
    case strip_meta(form) do
      {:list, [head | _]} ->
        case strip_meta(head) do
          {:symbol, ^name} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  # ── fallbacks ─────────────────────────────────────────────────────

  defp plain(form, exception, opts) do
    pos = position(form)
    loc = [pos[:file] || opts[:file], pos[:line]] |> Enum.reject(&is_nil/1) |> Enum.join(":")
    prefix = if loc == "", do: "", else: "#{loc}: "
    "#{prefix}#{Exception.message(exception)}"
  end

  defp read_source(nil), do: nil

  defp read_source(file) do
    case File.read(file) do
      {:ok, bytes} -> bytes
      {:error, _} -> nil
    end
  end

  defp first_line(msg) when is_binary(msg) do
    msg
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
  end

  defp first_line(other), do: other |> inspect() |> first_line()
end
