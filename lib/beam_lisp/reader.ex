defmodule BeamLisp.Reader.SyntaxError do
  defexception [:message]
end

defmodule BeamLisp.Reader.AtomLimitError do
  defexception [:message]
end

defmodule BeamLisp.Reader do
  @moduledoc """
  The host-facing front door to the SELF-HOSTED beam-lisp reader.

  beam-lisp's reader is written in beam-lisp (`priv/boot/reader.bl`). Once that
  source is AOT-compiled into `BeamLisp.Ns.Reader`, THIS module is a thin facade
  that delegates every entry point to it — the language reads itself. There is
  no Elixir genesis reader behind these functions any more: the original
  hand-written parser (`read_string_elixir` + its `defp` helpers) has been
  DELETED. A genesis-less tree boots the reader from the committed Core-Erlang
  seed (`priv/bootstrap/seed/`, installed by `BeamLisp.Bootstrap`).

  The facade keeps two things beyond pure delegation, both host glue, not
  reader semantics:

    * the `BeamLisp.Reader.SyntaxError` / `BeamLisp.Reader.AtomLimitError`
      exception structs the host raises, and the mapping from the .bl reader's
      internal errors (`BeamLisp.ExInfo`, `BeamLisp.AtomGuard.LimitError`) onto
      them, so Elixir callers keep `assert_raise`-ing the same types;
    * `enable_bl_reader/0`, the boot step that interns the reader ns from its
      beam.
  """

  @reader_ns BeamLisp.Ns.Reader

  @doc """
  Read binary `source` into position-bearing reader forms, attributed to `file`.

  THE reader entry every caller funnels through. Delegates to the self-hosted
  reader; maps its internal errors onto the host exception types.
  """
  @spec read_string(String.t()) :: [term]
  @spec read_string(String.t(), binary | nil) :: [term]
  def read_string(source, file \\ nil) when is_binary(source) do
    apply(@reader_ns, :read_string, [source, file])
  rescue
    e in BeamLisp.AtomGuard.LimitError ->
      reraise BeamLisp.Reader.AtomLimitError, [message: Exception.message(e)], __STACKTRACE__

    e in BeamLisp.ExInfo ->
      reraise BeamLisp.Reader.SyntaxError, [message: Exception.message(e)], __STACKTRACE__
  end

  @doc "Read `source` into a list of BARE reader forms (positions stripped)."
  @spec read_all(String.t()) :: [term]
  def read_all(source) when is_binary(source) do
    apply(@reader_ns, :read_all, [source])
  rescue
    e in BeamLisp.AtomGuard.LimitError ->
      reraise BeamLisp.Reader.AtomLimitError, [message: Exception.message(e)], __STACKTRACE__

    e in BeamLisp.ExInfo ->
      reraise BeamLisp.Reader.SyntaxError, [message: Exception.message(e)], __STACKTRACE__
  end

  @doc "Read exactly one bare form from `source`; raise if zero or many."
  @spec read_one(String.t()) :: term
  def read_one(source) when is_binary(source) do
    apply(@reader_ns, :read_one, [source])
  rescue
    e in BeamLisp.AtomGuard.LimitError ->
      reraise BeamLisp.Reader.AtomLimitError, [message: Exception.message(e)], __STACKTRACE__

    e in BeamLisp.ExInfo ->
      reraise BeamLisp.Reader.SyntaxError, [message: Exception.message(e)], __STACKTRACE__
  end

  @doc """
  Ensure the self-hosted beam-lisp reader is ready to serve `read_string/2`.

  Interns the `reader` namespace from its beam (the committed seed on a fresh
  tree, or the freshly built beam otherwise). No genesis reader remains behind
  it. Idempotent. Returns `:bl` when active, `:genesis` (legacy = "not active")
  otherwise.
  """
  def enable_bl_reader do
    unless BeamLisp.Env.loaded_ns?("reader") do
      BeamLisp.Loader.ensure_loaded("reader")
    end

    if BeamLisp.Env.loaded_ns?("reader"), do: :bl, else: :genesis
  end
end
