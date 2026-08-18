defmodule BeamLisp.Spell.HostRegenTest do
  @moduledoc """
  Publishing regenerates the HOST module, not just the page and the bundle.

  ## The defect

  The shell — the markup a LiveView renders for the bundle to hydrate into — is
  lifted from the machine by `spell.live/machine-shell` and baked into the
  generated `SpellWeb.ChatLive` by `spell.contract/elixir-module`. It is
  rendered SERVER-side, so it reaches the browser through the LiveView, not
  through the bundle.

  That generation ran in `scripts/serve_live.exs`, once, at boot. `publish/1`
  re-emitted `page.st` and rebuilt the bundle but never the host. So:

      a live model redefined chat-view (accepted, version 3, build :ok)
      → page.st and spacetime.js carried the new markup
      → the DOM kept boot's shell, through hard reloads
      → nothing anywhere reported an error

  The machine grew and the page could not change. `bundle_dir/2` documents this
  exact failure ("a machine that grows and a page that never changes, with no
  error anywhere") for the bundle; the host half was missed because the two
  halves of publishing lived in two files.

  ## What this asserts

  That the artefact carrying the shell is rebuilt from the CURRENT machine when
  the loop publishes — by changing the machine's shell and reading the file the
  loop wrote. Asserting "publish calls regenerate_host" would restate the
  implementation; asserting the file's CONTENT follows the machine is the
  property a browser actually depends on.

  Tagged `:verse` with the other rungs that shell out: publishing runs the real
  emitter and the real `spacetime build`.
  """

  use BeamLisp.SpellCase, async: false

  alias BeamLisp.Spell.Loop

  @moduletag :verse

  setup do
    out = Path.join(System.tmp_dir!(), "host-regen-#{System.unique_integer([:positive])}")
    gen = Path.join(out, "gen")
    File.mkdir_p!(gen)

    prev = Application.get_env(:beam_lisp, :spell_gen_dir)
    Application.put_env(:beam_lisp, :spell_gen_dir, gen)

    on_exit(fn ->
      if prev, do: Application.put_env(:beam_lisp, :spell_gen_dir, prev),
        else: Application.delete_env(:beam_lisp, :spell_gen_dir)

      File.rm_rf(out)
    end)

    {:ok, out: out, gen: gen}
  end

  test "the shell in the generated host follows the machine", %{out: out, gen: gen} do
    {:ok, pid} = Loop.start_link(out: out, name: nil)

    host = Path.join(gen, "chat_live.ex")
    assert :ok = Loop.rebuild(pid)
    assert File.exists?(host), "rebuilding must write the host module"

    # The seed's shell, as generated before the definition.
    before = File.read!(host)
    assert before =~ "shell:", "the generated module must carry a shell"

    # Redefining the view through the loop's own `run/2` — the path a model
    # takes — rather than reaching for a private function. The property is
    # about what an ACCEPTED DEFINITION does, so it must be driven by one.
    #
    # The definition is minimal but must survive all four rungs: `&shell` renders
    # `.log`, and the each-bind mounts into it, so no selector is orphaned.
    marker = "regen-#{System.unique_integer([:positive])}"

    source = """
    (defview chat-view
      (markup (template &shell []
        [:main {:class "chat" :data-marker "#{marker}"} [:div {:class "log" :data-log true}]])
               (template &message [$m]
        [:p {:class "bubble"} @m.text]))
      (binds [".log" (st/each @messages :as @m :template &message)]))
    """

    verdict = Loop.run(pid, source, "prove the host is regenerated from the machine")
    assert verdict.status == :ok, "the definition must be accepted: #{inspect(verdict)}"

    after_ = File.read!(host)

    assert after_ =~ marker,
           "publishing did not rebuild the host from the current machine — " <>
             "the page would keep rendering a stale shell"

    refute after_ == before

    GenServer.stop(pid)
  end

  test "a {@hole} in the shell is REFUSED rather than shipped as literal text", %{out: out} do
    # The shell is rendered by the LiveView, server-side, before the bundle
    # hydrates — and only the bundle's templates interpolate `{@name}`. A hole
    # written into the shell therefore reaches the browser as the literal
    # characters `{@partial}` and stays there.
    #
    # Observed live: asked to consume `@partial` and `@error`, a model put
    # `<p class="chat__partial">{@partial}</p>` in the shell AND added the
    # correct view bind. Every rung passed it — the markup is well-formed, the
    # class is rendered, the binding is declared — and the served page showed
    # `{@partial}` and `{@error}` as text under the transcript.
    #
    # The bind was right and the hole was wrong; nothing could tell the model
    # that, because the rule was known only to the host renderer. It is checked
    # where it is known, and stated in `machine-briefing` so a model is told
    # before it is refused.
    {:ok, pid} = Loop.start_link(out: out, name: nil)

    holed = """
    (defview chat-view
      (markup (template &shell []
        [:main {:class "chat"} [:div {:class "log" :data-log true}] [:p {:class "note"} @partial]])
               (template &message [$m]
        [:p {:class "bubble"} @m.text]))
      (binds [".log" (st/each @messages :as @m :template &message)]))
    """

    verdict = Loop.run(pid, holed, "a hole in the shell, which never interpolates")

    assert verdict.status == :published_stale,
           "a shell hole ships as literal text; it must not be reported as a " <>
             "clean success: #{inspect(verdict)}"

    reason = to_string(inspect(verdict.reason))

    assert reason =~ "{@partial}",
           "the refusal must quote the hole it found: #{reason}"

    assert reason =~ "server-side" or reason =~ "literal",
           "the refusal must say WHY, or the model will simply try again: #{reason}"

    GenServer.stop(pid)
  end
end
