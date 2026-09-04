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

  ## Errors: the language owns its own type

  A malformed source raises `BeamLisp.Reader.SyntaxError`, and the `.bl` reader
  raises THAT struct itself (`reader.bl`'s `syntax-error` does
  `(erlang/error (BeamLisp.Reader.SyntaxError/exception msg))`). So the facade
  does NOT translate reader errors — the type is the language's own contract,
  the same struct Elixir callers `assert_raise` on, raised at the source.

  One error the facade DOES still map is `BeamLisp.AtomGuard.LimitError`. That is
  not a reader concern: it is the host VM's atom-table high-water valve
  (`BeamLisp.AtomGuard`), raised from Elixir infrastructure that the reader runs
  *inside*, before a keyword/symbol can be interned. It is surfaced to callers as
  `BeamLisp.Reader.AtomLimitError` — a distinct type from a syntax error, so a
  test can assert exactly which failure it provoked. `mapping_atom_limit/1` is
  the one remaining host-glue seam.

  `enable_bl_reader/0` is the boot step that interns the reader ns from its beam.
  """

  @reader_ns BeamLisp.Ns.Reader

  @doc """
  Read binary `source` into position-bearing reader forms, attributed to `file`.

  THE reader entry every caller funnels through. Delegates to the self-hosted
  reader, which raises `BeamLisp.Reader.SyntaxError` itself on malformed input.
  """
  @spec read_string(String.t()) :: [term]
  @spec read_string(String.t(), binary | nil) :: [term]
  def read_string(source, file \\ nil) when is_binary(source) do
    mapping_atom_limit(fn -> apply(@reader_ns, :read_string, [source, file]) end)
  end

  @doc "Read `source` into a list of BARE reader forms (positions stripped)."
  @spec read_all(String.t()) :: [term]
  def read_all(source) when is_binary(source) do
    mapping_atom_limit(fn -> apply(@reader_ns, :read_all, [source]) end)
  end

  @doc "Read exactly one bare form from `source`; raise if zero or many."
  @spec read_one(String.t()) :: term
  def read_one(source) when is_binary(source) do
    mapping_atom_limit(fn -> apply(@reader_ns, :read_one, [source]) end)
  end

  # Run `fun`, surfacing the host VM's atom-table guard as the reader-facing
  # `AtomLimitError`. A `SyntaxError` from the `.bl` reader passes through
  # untouched — the language already raises the right type.
  defp mapping_atom_limit(fun) do
    fun.()
  rescue
    e in BeamLisp.AtomGuard.LimitError ->
      reraise BeamLisp.Reader.AtomLimitError, [message: Exception.message(e)], __STACKTRACE__
  end

  @doc """
  Ensure the self-hosted beam-lisp reader is ready to serve `read_string/2`.

  Interns the `reader` namespace from its beam (the committed seed on a fresh
  tree, or the freshly built beam otherwise). No genesis reader remains behind
  it. Idempotent. Returns `:bl` when active, `:not_loaded` if interning failed.
  """
  def enable_bl_reader do
    unless BeamLisp.Env.loaded_ns?("reader") do
      BeamLisp.Loader.ensure_loaded("reader")
    end

    if BeamLisp.Env.loaded_ns?("reader"), do: :bl, else: :not_loaded
  end
end
