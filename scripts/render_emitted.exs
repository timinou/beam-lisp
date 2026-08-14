# scripts/render_emitted.exs — build a screenshot-able page FROM the emitted view.
#
#   mix run scripts/render_emitted.exs <out.st> [thinking]
#
# ── why this exists
#
# The proof document showed screenshots of `docs/proof/chat.st`, a page written
# by hand to look like what `defview` emits. A milestone-3 reviewer compared the
# two and found they had drifted: the hand-written page had no `&shell`, no
# `&thinking`, and no send binding. The image was a picture of a mockup, and the
# caption said it was a picture of the emitted view.
#
# The honest fix is not a better caption. It is to render the real thing.
#
# ── what a page needs that a view does not have
#
# `(chat/view-page)` emits three planes: markup, style, binds. That is the whole
# view and it is genuinely all of it — but a view is not a page. A page also
# needs DATA (`@data inline $messages : […]`) and the SIGNAL declarations the
# binds fire into, both of which come from the running server: `$messages` is
# the LiveView's assign, `$send` is the event the contract declares.
#
# So this script takes the emitted planes verbatim — printed by `spacetime st`
# from the emitted EDN, not re-derived — and prepends exactly the two things a
# server would supply. Everything below the `── emitted ──` marker in the output
# is bytes from the emitter; everything above it is the stand-in for the server.
#
# That division is the point. A reader can see precisely where the generated
# half stops.

verse = Path.expand("~/code/ora/verse")
[out | rest] = System.argv()
thinking? = "thinking" in rest

BeamLisp.init()
for f <- ~w(seam contract chat), do: BeamLisp.Compiler.eval_string(File.read!("priv/#{f}.bl"))

# BOTH emitted documents, because both halves come from the same term:
#   page-document — the seam (`@data subscribe/signal/stream`), client side
#   view-page     — the three planes (markup, style, binds)
# The point of the whole build is that these cannot disagree, so a page that
# renders one and hand-writes the other would prove nothing.
print_st = fn edn, label ->
  path = Path.join(System.tmp_dir!(), "render_emitted_#{label}.edn")
  File.write!(path, edn)

  {out, 0} =
    System.cmd("cargo", ["run", "--quiet", "--bin", "spacetime", "--", "st", path], cd: verse)

  File.rm(path)
  {out, byte_size(edn)}
end

{seam, seam_bytes} = print_st.(BeamLisp.Compiler.eval_string("(chat/page-document)"), "page")
{emitted, view_bytes} = print_st.(BeamLisp.Compiler.eval_string("(chat/view-page)"), "view")

# The conversation the server would have assigned. Written as the `@data inline`
# a LiveView produces, because that is what the page receives.
messages =
  if thinking? do
    [
      {"user", "What is a contract, in one sentence?"},
      {"model",
       "A contract is the seam between two runtimes, written once so neither half can drift from the other."},
      {"user", "And who checks it?"}
    ]
  else
    [
      {"user", "What is a contract, in one sentence?"},
      {"model",
       "A contract is the seam between two runtimes, written once so neither half can drift from the other."},
      {"user", "And who checks it?"},
      {"model",
       "The compiler does — a reply the page cannot decode is a build error, not a surprise in the browser."}
    ]
  end

rows =
  messages
  |> Enum.map(fn {role, text} ->
    ~s(  { role: "#{role}",  text: "#{String.replace(text, ~s("), ~s(\\"))}" })
  end)
  |> Enum.join(",\n")

# What a SCREENSHOT needs that a running app does not.
#
# The emitted seam declares `@data subscribe $messages from $chat` — the assign
# arrives over the wire from the LiveView. There is no LiveView behind a static
# screenshot, so the conversation is supplied as `@data inline` instead, and
# `$draft` is the page-local the composer writes into.
#
# That substitution is the ONLY thing standing in for the server, and the page
# says so where it happens. Everything between the markers is emitter output.
server_half = """
/* Stand-ins for the running server: the emitted seam SUBSCRIBES `$messages`
   from the live host, so a static screenshot must supply the conversation the
   LiveView would have pushed. `$draft` is the page-local the composer writes.
   `$chat` is the host the contract belongs to.

   Everything between the markers below is emitted, byte for byte. */
@import "stdlib/macros/data-kind"
@import "stdlib/macros/each"
@import "stdlib/macros/on"
@import "stdlib/macros/host"
@import "stdlib/macros/handle"

@host $chat : live("SpacetimeLvWeb.ChatLive")

@data inline $draft : "";

/* ── emitted: the seam (defcontract) ──────────────────────────────────── */
#{seam}
/* ── emitted: the view (defview) ─────────────────────────────────────── */
"""

# The presentation the page carries anyway. Kept separate from the emitted
# planes so it is obvious this is not pretending to be generated.
chrome = """

body {
  margin: 0;
  background: #05070d;
  font-family: Inter, ui-sans-serif, system-ui, sans-serif;
  color: #e7ecf5;
}
.chat {
  display: grid;
  grid-template-rows: 1fr auto;
  height: 100vh;
  max-width: 720px;
  margin: 0 auto;
  padding: 1.25rem;
  box-sizing: border-box;
  gap: 1rem;
}
.log {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  overflow-y: auto;
  padding: 0.5rem;
}
.bubble {
  max-width: 78%;
  padding: 0.75rem 1rem;
  border-radius: 1rem;
  line-height: 1.5;
  font-size: 0.95rem;
}
.bubble[data-role='user'] {
  align-self: flex-end;
  background: #1d3f7a;
}
.bubble[data-role='model'] {
  align-self: flex-start;
  background: #131926;
  border: 1px solid #1e2839;
}
.bubble__text { margin: 0; }
.composer {
  display: flex;
  gap: 0.6rem;
}
.composer__input {
  flex: 1;
  padding: 0.75rem 1rem;
  border-radius: 0.75rem;
  border: 1px solid #1e2839;
  background: #0b111c;
  color: #e7ecf5;
  font-size: 0.95rem;
}
.composer__send {
  padding: 0.75rem 1.25rem;
  border-radius: 0.75rem;
  border: 0;
  background: #3b6fd4;
  color: #fff;
  cursor: pointer;
}
.thinking {
  align-self: flex-start;
  display: flex;
  gap: 0.35rem;
  padding: 0.9rem 1rem;
}
.thinking > span {
  width: 0.5rem;
  height: 0.5rem;
  border-radius: 50%;
  background: #4a5a75;
}
"""

File.write!(out, server_half <> emitted <> chrome)

# The host page, with the assign seed the LiveView would have pushed.
#
# `@data subscribe $messages from $chat` is a SUBSCRIPTION: it initialises to
# null and waits for the server. Declaring `@data inline $messages` alongside it
# does not seed it — it declares the same binding twice, and the subscription's
# `null` init wins, which rendered an empty log against a page that compiled
# perfectly.
#
# So seed it the way the bridge does: `window.SpacetimeLocal[name] = value`,
# which is the documented assign->signal seam (`live_view.ex`: "on phx:st-set
# push_events from the server, write the value into window.SpacetimeLocal").
# The stand-in is the TRANSPORT, not the declaration.
seed =
  messages
  |> Enum.map(fn {role, text} -> %{"role" => role, "text" => text} end)
  |> JSON.encode!()

# The thinking indicator is the EMITTED `&thinking` template, lifted out of the
# document rather than written again here. `@status` drives it in the running
# app (`(assign @status :atom :idle)`); a static capture has no status to react
# to, so the template's own markup is placed as a SIBLING of the log — inside
# it, the `@each` renderer owns the subtree and replaces whatever it finds.
#
# Taking it from the emitted text is the point: if `&thinking` changed, this
# picture changes with it. An indicator hand-written here would keep looking
# right long after the template stopped saying so — which is exactly the drift
# that made the previous screenshots a mockup.
# The DOM skeleton comes from the emitted `&shell`, not from a copy of it.
#
# A reviewer caught the copy: the host page hard-coded the same `<main>/<div>/
# <form>` markup that `&shell` emits, so if the emitter dropped or changed the
# shell the screenshot would keep rendering the stale copy and stay green. That
# is the ORIGINAL failure of this document — a picture of a page the emitter did
# not produce — surviving in the one plane nobody had checked.
#
# `&shell` is the mount point the signal renderer binds onto, so it has to exist
# in the host HTML before the bundle runs; it cannot be instantiated by the page
# itself. Lifting it out of the emitted text is the way to have both.
shell_markup =
  case Regex.run(~r/@template &shell\(\) \{(.*?)\}\s*$/m, emitted) do
    [_, markup] ->
      String.trim(markup)

    _ ->
      raise """
      could not find the emitted &shell template.

      The host skeleton must come from the view, or the screenshot stops being
      evidence about the view.

      emitted:
      #{emitted}
      """
  end

thinking_markup =
  if thinking? do
    case Regex.run(~r/@template &thinking\(\) \{(.*?)\}\s*$/m, emitted) do
      [_, markup] ->
        String.trim(markup)

      _ ->
        raise """
        could not find the emitted &thinking template.

        The screenshot must show what the view emits, so falling back to
        hand-written markup here would defeat the purpose of the capture.

        emitted:
        #{emitted}
        """
    end
  else
    ""
  end

host = """
<!doctype html>
<html><head><meta charset="utf-8"><link rel="stylesheet" href="spacetime.css"></head>
<body>
  #{shell_markup}
  #{thinking_markup}
  <script src="spacetime.js"></script>
  <script>
    // The assign the LiveView pushes on connect, through the same channel the
    // bridge uses. Not a redeclaration of `$messages` — a write to it.
    (function () {
      var seed = #{seed};
      function push() {
        if (!window.SpacetimeLocal) return false;
        window.SpacetimeLocal["messages"] = seed;
        document.dispatchEvent(
          new CustomEvent("local:messages:updated", { detail: seed })
        );
        return true;
      }
      if (!push()) {
        var t = setInterval(function () { if (push()) clearInterval(t); }, 10);
        setTimeout(function () { clearInterval(t); }, 4000);
      }
    })();
  </script>
</body></html>
"""

host_path = String.replace_suffix(out, ".st", ".host.html")
File.write!(host_path, host)

total = byte_size(File.read!(out))
generated = byte_size(seam) + byte_size(emitted)

IO.puts("wrote #{out} (#{total} B)")
IO.puts("  seam  #{seam_bytes} B EDN -> #{byte_size(seam)} B .st   (chat/page-document)")
IO.puts("  view  #{view_bytes} B EDN -> #{byte_size(emitted)} B .st   (chat/view-page)")

IO.puts(
  "  #{generated} of #{total} B generated; the rest is the conversation a " <>
    "LiveView would push, plus presentation"
)

IO.puts("  host  #{host_path} (seeds $messages the way the bridge does)")
