defmodule BeamLisp.Spell.Page do
  @moduledoc """
  Emit a whole machine as one `.st` page.

  The machine holds contracts and views. A page needs both halves plus the
  things only a running server supplies — a `@host` per contract, and the
  page-local `@data inline` signals the browser writes into.

  ## What is generated, and from where

  Everything below the emitted marker comes from the terms:

    * seam and views — printed by `spacetime st` from the emitted EDN, so the
      compiler's own printer decides what they look like;
    * the style plane — printed by `spell.live/machine-css`, because
      `spacetime st` does not print `:st/scopes`. Not a second source of truth:
      the same `(get v :style)` data, printed by us because verse's printer
      does not print it.

  The preamble above the marker stands in for the server, and is DERIVED from
  the machine rather than hand-listed:

    * `@host` per registered contract — the seam says `from $chat-live`, so a
      page declaring some other host name leaves every data source unbound.
      Verse reports that as W0201 "defined but never used", which reads like
      dead code and actually means the page is wired to nothing.
    * `@data inline` per page-local SIGNAL — `spell.live/machine-locals` uses
      `view-signals`, not `view-locals`, so `@each` loop variables are excluded:
      declaring one as a page signal creates a second, permanently empty name a
      template could resolve to instead.

  That division is kept visible in the output. `scripts/render_emitted.exs`
  records why: a proof document once screenshotted a hand-written page that had
  drifted from the emitter's output, with a caption claiming it was generated.
  """

  alias BeamLisp.Spell

  @doc """
  Write the machine's page to `path`; `{:ok, path}` | `{:error, reason}`.

  `machine` is the machine VALUE — what `spell.define/define` returns under
  `:machine`, or what the loop holds in its state.

  It used to be a beam-lisp EXPRESSION (a string, typically the name of a var
  the caller had bound), interpolated into five `eval_string` calls. That made
  emitting cost five compiled BEAM modules, and it forced every caller to first
  publish its machine to a global var — which is how two writers of
  `live-machine` came to exist, each silently overwriting the other. A value
  parameter removes both: nothing is compiled, and nothing has to be global to
  be passed.
  """
  def emit(machine, path, opts \\ []) do
    prefix = Keyword.get(opts, :module_prefix, "SpellWeb")

    with {:ok, seam_edn} <- call("machine-seam-edn", machine),
         {:ok, view_edn} <- call("machine-view-edn", machine),
         {:ok, locals} <- call_list("machine-locals", machine),
         {:ok, hosts} <- call_list("machine-hosts", machine),
         {:ok, css} <- call("machine-css", machine),
         {:ok, seam_st} <- print_st(seam_edn, "seam"),
         {:ok, view_st} <- print_st(view_edn, "view") do
      File.write!(path, render(seam_st, view_st, locals, hosts, css, prefix))
      {:ok, path}
    end
  end

  @doc """
  The page's text, from already-printed parts. Pure: no machine, no subprocess,
  no filesystem.

  Public because it is the half that can be checked without a compiler, and
  because the split is the layering: `emit/3` gathers (asks the machine, shells
  out to verse's printer, writes a file) and this renders. A caller with the
  five parts in hand — a test, or a future emitter living in beam-lisp — needs
  the rendering without the gathering.

    * `seam_st` / `view_st` — documents already printed by `spacetime st`
    * `locals` — page-local signal names (`spell.live/machine-locals`)
    * `hosts` — registered contract names (`spell.live/machine-hosts`)
    * `css` — the style plane (`spell.live/machine-css`)
    * `prefix` — the module namespace hosts resolve into
  """
  def render(seam_st, view_st, locals, hosts, css, prefix) do
    host_decls =
      Enum.map_join(hosts, "\n", fn h ->
        "@host $" <> h <> " : live(\"" <> prefix <> "." <> module_name(h) <> "\")"
      end)

    local_decls =
      Enum.map_join(locals, "\n", fn l -> "@data inline $" <> l <> " : \"\";" end)

    """
    /* Emitted from the machine by BeamLisp.Spell.Page.

       Above the marker: what a running server supplies — a @host per registered
       contract and the page-local signals the browser writes into. Both are
       DERIVED from the machine, so this page cannot reference a host no
       contract declares or a local the checker did not know about.

       Below it: the terms. Seam and views are printed by verse's own printer;
       the style plane by spell.live/machine-css, because `spacetime st` does
       not print :st/scopes. */
    @import "stdlib/macros/data-kind"
    @import "stdlib/macros/each"
    @import "stdlib/macros/on"
    @import "stdlib/macros/host"
    @import "stdlib/macros/handle"
    @import "stdlib/enum/dispatch"

    #{host_decls}

    #{local_decls}

    /* ── emitted: the seam ─────────────────────────────────────────── */
    #{seam_st}

    /* ── emitted: the views ────────────────────────────────────────── */
    #{view_st}

    /* ── emitted: the style plane ──────────────────────────────────── */
    #{css}
    /* ── end emitted ───────────────────────────────────────────────── */
    """
  end

  # chat-live → ChatLive, matching `spell.contract/module-name` EXACTLY.
  #
  # `String.capitalize/1` was wrong and a reviewer caught it: it lowercases the
  # rest of a segment, so a contract named `HTTP-live` — whose seam says
  # `from $HTTP-live` and whose BEAM module is `HTTPLive` — would get a page
  # declaring `@host $HTTP-live : live("…HttpLive")`, pointing at a module the
  # contract does not describe. Upcase the first character, keep the rest.
  defp module_name(host) do
    host
    |> String.split("-")
    |> Enum.map_join("", fn
      "" -> ""
      <<first::utf8, rest::binary>> -> String.upcase(<<first::utf8>>) <> rest
    end)
  end

  # An emitted EDN document as `.st`, via verse's own printer — never by
  # re-deriving the text here. A second printer would be a second source of
  # truth about what the emitter produced, and the two would drift.
  #
  # Delegated to Spell.Verse so the cwd discipline (spacetime resolves its
  # stdlib registry relative to cwd) lives in exactly one place.
  defp print_st(edn, label) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "spell_page_#{label}_#{System.unique_integer([:positive])}.edn"
      )

    File.write!(tmp, edn)

    try do
      case Spell.Verse.print_st(tmp) do
        {:ok, st} -> {:ok, st}
        {:error, reason} -> {:error, "#{label}: #{reason}"}
      end
    after
      File.rm(tmp)
    end
  end

  # `spell.live/<name>` applied to the machine.
  #
  # Fetched per call rather than cached: `BeamLisp.Env` is where a REDEFINED var
  # lands, and a cached capture would keep running the definition that existed
  # at boot — which in a system whose entire purpose is growing itself at
  # runtime is a silent opt-out. The lookup is an ETS read.
  defp call(name, machine) do
    {:ok, apply(BeamLisp.Env.fetch!("spell.live", name), [machine])}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp call_list(name, machine) do
    case call(name, machine) do
      {:ok, %BeamLisp.Vector{} = v} -> {:ok, BeamLisp.Vector.to_list(v)}
      {:ok, l} when is_list(l) -> {:ok, l}
      {:ok, other} -> {:error, "expected a list, got #{inspect(other)}"}
      err -> err
    end
  end
end
