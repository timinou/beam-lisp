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
@data subscribe $messages from $chat : messages;
@data subscribe $status from $chat : status;
@data signal $send() to $chat { send emit "send" receive to SendResult { _ => Failed ($.reply); "ok" => Ok ($.reply); } policy latest }
@data stream $fx from $chat { receive to Effect { "failed" => Failed ($.payload); "token" => Token ($.payload); } }

/* ── emitted: the view (defview) ─────────────────────────────────────── */
@template &shell() { <main class='chat'><div class='log' data-log></div><form class='composer'><input class='composer__input' placeholder='Say something…'><button class='composer__send' type='button'>Send</button></form></main> }
@template &bubble($m) { <article class='bubble' data-role='`$m.role`'><p class='bubble__text'>`$m.text`</p></article> }
@template &thinking() { <div class='thinking'><span></span><span></span><span></span></div> }
.log {
  @each($messages as $m, key: null) { &bubble($m); }
}
.composer__input {
  @on &.input { $draft <- $.value; }
}
.composer__send {
  @on &.click { $send ($draft,); }
}

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
