/* chat.st — HAND-WRITTEN. Not emitter output.

   This file's header used to claim "the three planes below are exactly what
   `view-page` emits". That was false, and a milestone-3 reviewer caught it by
   comparing the two: this page has no `&shell`, no `&thinking`, and no send
   binding. It is a page written to LOOK like the emitted view, and it drifted.

   It is kept for two reasons. It is the artifact that made the drift visible
   (`matches=7 scopes=13` here versus `matches=3 scopes=12` emitted, which is
   how the missing template declarations were found), and `scripts/live_chat.exs`
   still borrows its stylesheet.

   For the real thing see `chat-emitted.st`, built by
   `scripts/render_emitted.exs` from `(chat/page-document)` and
   `(chat/view-page)` — both printed through `spacetime st` and pasted in
   verbatim between markers. */
@import "stdlib/macros/data-kind"
@import "stdlib/macros/each"

@data inline $messages : [
  { role: "user",  text: "What is a contract, in one sentence?" },
  { role: "model", text: "A contract is the seam between two runtimes, written once so neither half can drift from the other." },
  { role: "user",  text: "And who checks it?" },
  { role: "model", text: "The compiler does — a reply the page cannot decode is a build error, not a surprise in the browser." }
];
@data inline $draft : "";

@template &bubble($m) {
  <article class="bubble" data-role="`$m.role`">
    <p class="bubble__text">`$m.text`</p>
  </article>
}

.log { @each($messages as $m) { &bubble($m); } }
.composer__input { value <- $draft; @on &.input { $draft <- $.value; } }

body {
  margin: 0;
  background: #05070d;
  font-family: Inter, ui-sans-serif, system-ui, sans-serif;
}
.chat {
  display: grid;
  grid-template-rows: 1fr auto;
  height: 100vh;
  max-width: 48rem;
  margin: 0 auto;
  background: #0b0d14;
  color: #e8eaf2;
}
.log {
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  padding: 1.5rem;
}
.bubble {
  padding: 0.75rem 1rem;
  border-radius: 1rem;
  max-width: 80%;
  white-space: pre-wrap;
  line-height: 1.5;
}
.bubble[data-role="user"] { align-self: flex-end; background: #2b4c8c; }
.bubble[data-role="model"] { align-self: flex-start; background: #1b2030; }
.bubble__text { margin: 0; }
.composer {
  display: flex;
  gap: 0.5rem;
  padding: 1rem;
  border-top: 1px solid rgba(255, 255, 255, 0.08);
}
.composer__input {
  flex: 1;
  padding: 0.75rem 1rem;
  border-radius: 0.75rem;
  border: 1px solid rgba(255, 255, 255, 0.12);
  background: #141824;
  color: #e8eaf2;
  font-size: 1rem;
}
.composer__send {
  padding: 0.75rem 1.25rem;
  border-radius: 0.75rem;
  border: 0;
  background: #3b6fd4;
  color: #fff;
  font-size: 1rem;
  cursor: pointer;
}
