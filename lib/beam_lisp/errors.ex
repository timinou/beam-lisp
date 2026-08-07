defmodule BeamLisp.CompileError do
  @moduledoc """
  A compile-time error in beam-lisp source, carrying the position and the
  offending form so the message names the user's file and line instead of
  the compiler's own frames.

  The message keeps the compiler's original wording (so existing tests
  that assert on its substring still match) but is prefixed with the
  `file:line` location when known, and the offending form is appended.
  `file`/`line`/`form` are each optional: forms built by a macro at
  runtime carry no position, and the error is still reported.
  """

  defexception [:message, :file, :line, :form]

  @impl true
  def exception(opts) when is_list(opts) do
    message = Keyword.fetch!(opts, :message)
    file = Keyword.get(opts, :file)
    line = Keyword.get(opts, :line)
    form = Keyword.get(opts, :form)

    %__MODULE__{
      message: build_message(message, file, line, form),
      file: file,
      line: line,
      form: form
    }
  end

  def exception(message) when is_binary(message), do: %__MODULE__{message: message}

  defp build_message(message, file, line, form) do
    location =
      cond do
        file && line -> "#{file}:#{line}"
        file -> file
        line -> "line #{line}"
        true -> nil
      end

    prefix = if location, do: "#{location}: ", else: ""
    form_suffix = if form, do: "\n  offending form: #{inspect(form)}", else: ""
    "#{prefix}#{message}#{form_suffix}"
  end
end
