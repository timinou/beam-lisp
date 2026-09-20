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

  ## Errors: the language owns its own VALUE, the host owns the rendering

  A malformed source makes the `.bl` reader raise a DIAGNOSTIC — the tree's one
  diagnostic shape, defined and enforced in `priv/boot/diag.bl`:
  `{:diag true, :severity, :kind, :msg, :line, :col, :offset, :end-line,
  :end-col, :end-offset, :file, …}`. The same shape the type checker's warnings
  take, so one renderer (`priv/std/errors.bl`) draws a caret under any of them.
  `:kind` names what went wrong, `:expected`/`:opened-at` name the delimiter a
  human forgot and where its collection opened, and the offsets locate the
  offending text.

  THIS module turns that value into `BeamLisp.Reader.SyntaxError` for its own
  callers, using the diagnostic's `:msg` verbatim — the host type is a RENDERING
  at the boundary, not the language's error vocabulary. A beam-lisp caller never
  needs this module: it can `(catch e (:original e))` and read the diagnostic, or
  ask `(read src {:diagnostics :collect})` for `{:error diag}` with no raise at
  all.

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
  reader, and renders a reader diagnostic (`{:diag true, :msg, …}`) as
  `BeamLisp.Reader.SyntaxError` on the way out.
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
  # `AtomLimitError`, and RENDERING a reader diagnostic into this module's error
  # type.
  #
  # The language raises a diagnostic VALUE, not a host struct: a map carrying
  # `{:diag true, :kind, :msg, :line, :col, :offset, :end-line, :end-col,
  # :end-offset, …}` — the same shape the type checker's warnings take, so
  # `errors/render` draws its caret from it. `SyntaxError` is THIS boundary's
  # rendering of that value, which is why the `.bl` reader needs no host
  # vocabulary of its own: swap this front door for a beam-lisp one and the
  # diagnostics are unchanged.
  #
  # Anything that is not a reader diagnostic passes through untouched, so
  # nothing is swallowed.
  defp mapping_atom_limit(fun) do
    fun.()
  rescue
    e in BeamLisp.AtomGuard.LimitError ->
      reraise BeamLisp.Reader.AtomLimitError, [message: Exception.message(e)], __STACKTRACE__

    e in ErlangError ->
      case e.original do
        %{diag: true, msg: msg} when is_binary(msg) ->
          reraise BeamLisp.Reader.SyntaxError, [message: msg], __STACKTRACE__

        # `:bl_diag` is the spelling this marker carried before the vocabulary
        # landed as `priv/boot/diag.bl` (`:diag`). Accepted while the reader
        # side of that move is in flight in another session, so this front door
        # is correct against EITHER reader; delete this clause when no producer
        # writes it.
        %{bl_diag: true, msg: msg} when is_binary(msg) ->
          reraise BeamLisp.Reader.SyntaxError, [message: msg], __STACKTRACE__

        _ ->
          reraise e, __STACKTRACE__
      end
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
