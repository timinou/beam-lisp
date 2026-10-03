// apps/bl-ed/web/host.mjs — the browser host for bl-ed.
//
// Everything the editor DECIDES is Beam Lisp (ed.* compiled by the sync JS
// profile). This file only:
//   * turns DOM input into editor events  {:type :key|:text|:click|:resize}
//   * draws the render model BL returns    (lines → segments → spans)
//   * performs the effects BL asks for     (:save :eval-cell :clipboard-write)
//
// Input goes through a hidden <textarea> that keeps focus, the technique
// CodeMirror 6 and Monaco use: keydown carries commands, `input` carries
// text (IME compositions, dead keys, paste) — so a composed "é" or a pasted
// paragraph reaches BL as ONE :text event, never as raw key codes.
//
// Rendering is keyed by row and diffed against the previous frame per line,
// so a keystroke repaints the lines it changed, not the viewport.

import * as R from "./out/rt.mjs";
import * as M from "./out/ed.main.mjs";

const K = R.kw;
const get = (m, k) => (m == null ? null : m.get(K(k), null));
const ev = (...kv) => R.hashMap(...kv);

// ─── DOM scaffold ──────────────────────────────────────────────────────────

const $ = (sel) => document.querySelector(sel);
const view = $("#lines");
const gutter = $("#gutter");
const sink = $("#input-sink");
const status = $("#status");
const echo = $("#echo");
const minibuf = $("#minibuf");
const overlay = $("#overlay");
const selLayer = $("#selections");
const caret = $("#caret");

let ed = null;
let metrics = { line: 22, ch: 8.4 };       // measured once fonts load
let prevLines = new Map();                  // row → signature, for diffing

function measure() {
  // the row height is a CSS token (--row); every line is exactly that tall,
  // so line N is at y = N * row with no per-line measurement
  const row = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--row"));
  const probe = document.createElement("span");
  probe.className = "seg";
  probe.textContent = "M".repeat(100);
  view.appendChild(probe);
  metrics.ch = probe.getBoundingClientRect().width / 100;
  metrics.line = row || probe.getBoundingClientRect().height;
  probe.remove();
}

// ─── the loop ──────────────────────────────────────────────────────────────

function dispatch(event) {
  const t0 = performance.now();
  ed = M.d_handle(ed, event);
  const [ed2, effects] = M.d_take_effects(ed).toArray();
  ed = ed2;
  for (const e of effects) perform(e);
  draw();
  const dt = performance.now() - t0;
  lastFrame.push(dt); if (lastFrame.length > 60) lastFrame.shift();
}
const lastFrame = [];
window.blEdStats = () => {
  const s = [...lastFrame].sort((a, b) => a - b);
  return { frames: s.length, p50: s[Math.floor(s.length * 0.5)], p95: s[Math.floor(s.length * 0.95)], max: s[s.length - 1] };
};

// ─── effects ───────────────────────────────────────────────────────────────

async function perform(e) {
  const kind = get(e, "kind").name;
  if (kind === "save") {
    const body = { path: get(e, "path"), text: get(e, "text") };
    try {
      const r = await fetch("/api/save", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
      const j = await r.json();
      dispatch(ev(K("type"), K("saved"), K("rev"), get(e, "rev"), K("ok?"), r.ok && j.ok === true, K("message"), j.message || ""));
    } catch (err) {
      // no server (opened as a static page): fall back to a download
      download(body.path.split("/").pop(), body.text);
      dispatch(ev(K("type"), K("saved"), K("rev"), get(e, "rev"), K("ok?"), true, K("message"), "downloaded"));
    }
  } else if (kind === "eval-cell") {
    try {
      const r = await fetch("/api/eval", { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ path: get(e, "path"), id: get(e, "id"), text: get(e, "text") }) });
      const j = await r.json();
      if (j.text != null) dispatch(ev(K("type"), K("load"), K("text"), j.text, K("path"), get(e, "path")));
      dispatch(ev(K("type"), K("eval-result"), K("id"), get(e, "id"), K("text"), j.result || j.message || "done"));
    } catch (err) {
      dispatch(ev(K("type"), K("eval-result"), K("id"), get(e, "id"), K("text"), "no evaluation server — run `bl run apps/bl-ed/serve.bl`"));
    }
  } else if (kind === "clipboard-write") {
    navigator.clipboard?.writeText(get(e, "text")).catch(() => {});
  }
}

function download(name, text) {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([text], { type: "text/plain" }));
  a.download = name || "untitled.bl.org";
  a.click();
  URL.revokeObjectURL(a.href);
}

// ─── drawing ───────────────────────────────────────────────────────────────

function segSig(segs) { let s = ""; for (const g of segs) s += get(g, "kind").name + "\u0001" + get(g, "text") + "\u0002"; return s; }

function draw() {
  const v = M.d_render(ed);
  const lines = get(v, "lines");
  const top = get(v, "top");

  // lines: rebuild only rows whose content signature changed
  const nextLines = new Map();
  const frag = [];
  for (const ln of lines) {
    const row = get(ln, "row");
    const segs = get(ln, "segments");
    const band = get(ln, "band");
    const cls = "line" + (band ? " in-cell band-" + band : "") + (get(ln, "band-first?") ? " first" : "") +
      (get(ln, "band-last?") ? " last" : "") + (get(ln, "current?") ? " cur-line" : "");
    const sig = segSig(segs) + (get(ln, "folded?") ? "\u0003" : "") + "\u0004" + cls;
    nextLines.set(row, sig);
    frag.push([row, sig, segs, get(ln, "folded?"), cls, get(ln, "current?")]);
  }
  // Reconcile by SLOT: slot i shows row frag[i]. A slot is touched only when
  // its row's signature changed (a scroll shifts every slot; a keystroke
  // usually touches one or two). The gutter is reconciled the same way.
  for (let i = 0; i < frag.length; i++) {
    const [row, sig, segs, folded, cls, current] = frag[i];
    let node = view.children[i];
    if (!node || node.dataset.sig !== sig) {
      const fresh = document.createElement("div");
      fresh.className = cls;
      fresh.dataset.row = row;
      fresh.dataset.sig = sig;
      for (const g of segs) {
        const s = document.createElement("span");
        s.className = "seg k-" + get(g, "kind").name;
        s.textContent = get(g, "text");
        fresh.appendChild(s);
      }
      if (folded) { const f = document.createElement("span"); f.className = "fold-mark"; f.textContent = " ⋯"; fresh.appendChild(f); }
      if (segs.cnt === 0) fresh.appendChild(document.createTextNode("\u200b"));
      if (node) view.replaceChild(fresh, node); else view.appendChild(fresh);
    }
    let g = gutter.children[i];
    const gcls = "gnum" + (current ? " cur" : ""), gtxt = String(row + 1);
    if (!g) { g = document.createElement("div"); gutter.appendChild(g); }
    if (g.className !== gcls) g.className = gcls;
    if (g.textContent !== gtxt) g.textContent = gtxt;
  }
  while (view.children.length > frag.length) view.lastChild.remove();
  while (gutter.children.length > frag.length) gutter.lastChild.remove();
  prevLines = nextLines;

  // selections + caret, positioned by grapheme column → pixel (measured per line)
  const slotOf = new Map(frag.map((f, i) => [f[0], i]));
  const yOf = (row) => { const i = slotOf.get(row); return i === undefined ? null : i * metrics.line; };
  // selections: reuse box elements by index
  let boxI = 0;
  const box = () => { let b = selLayer.children[boxI++]; if (!b) { b = document.createElement("div"); selLayer.appendChild(b); } return b; };
  for (const s of get(v, "sels")) {
    const from = get(s, "from").toArray(), to = get(s, "to").toArray();
    for (let r = from[0]; r <= to[0]; r++) {
      const y = yOf(r); if (y == null) continue;
      const c0 = r === from[0] ? from[1] : 0;
      const c1 = r === to[0] ? to[1] : lineLen(r) + 1;
      if (c1 <= c0 && !(r < to[0])) continue;
      const b = box();
      b.className = "sel" + (get(s, "primary?") ? " primary" : "");
      const x0 = xOf(r, c0), x1 = xOf(r, Math.max(c1, c0 + (r < to[0] ? 1 : 0)));
      b.style.cssText = `top:${y}px;left:${x0}px;width:${Math.max(2, x1 - x0)}px;height:${metrics.line}px`;
    }
  }
  while (selLayer.children.length > boxI) selLayer.lastChild.remove();
  const cur = get(v, "cursor").toArray();
  const cy = yOf(cur[0]);
  const m = get(v, "mode").name;
  document.body.dataset.mode = m;
  if (cy != null) {
    caret.style.cssText = `top:${cy}px;left:${xOf(cur[0], cur[1])}px;height:${metrics.line}px;` +
      (m === "insert" ? "width:2px" : `width:${Math.max(metrics.ch, xOf(cur[0], cur[1] + 1) - xOf(cur[0], cur[1]))}px`);
    caret.hidden = false;
    // keep the hidden input under the caret so the IME popup appears there
    sink.style.top = cy + "px"; sink.style.left = xOf(cur[0], cur[1]) + "px";
  } else caret.hidden = true;

  // status line
  const st = get(v, "status");
  const pos = get(st, "pos").toArray();
  status.innerHTML = "";
  const chip = (cls, text) => { const s = document.createElement("span"); s.className = cls; s.textContent = text; status.appendChild(s); };
  chip("mode-chip m-" + m, { normal: "NOR", insert: "INS", select: "SEL", command: "CMD", palette: "M-x" }[m] || m);
  chip("file", (get(st, "path") || "untitled") + (get(st, "dirty?") ? " ●" : ""));
  if (get(st, "section")) chip("crumb", "§ " + get(st, "section"));
  if (get(st, "block")) chip("crumb", get(st, "block"));
  if (get(st, "problems") > 0) chip("problems", get(st, "problems") + " unbalanced");
  const pend = get(st, "pending");
  if (pend) chip("pending", pend + (get(st, "count") ? " ×" + get(st, "count") : ""));
  else if (get(st, "count")) chip("pending", "×" + get(st, "count"));
  chip("spacer", "");
  if (get(st, "sels") > 1) chip("cursors", get(st, "sels") + " sel");
  chip("pos", pos[0] + ":" + pos[1]);

  echo.textContent = get(v, "message") || "";
  echo.classList.toggle("error", /^(error|read error|save failed)/.test(echo.textContent));

  // minibuffer
  const mb = get(v, "minibuf");
  if (mb) {
    minibuf.hidden = false;
    minibuf.querySelector(".prompt").textContent = get(mb, "prompt");
    minibuf.querySelector(".text").textContent = get(mb, "text");
    const list = minibuf.querySelector(".matches");
    list.textContent = "";
    const sel = get(mb, "sel");
    get(mb, "matches").toArray().forEach((x, i) => {
      const li = document.createElement("li");
      if (i === sel) li.className = "active";
      const n = document.createElement("span"); n.className = "name"; n.textContent = get(x, "name");
      const d = document.createElement("span"); d.className = "doc"; d.textContent = get(x, "doc");
      const k = document.createElement("span"); k.className = "keys"; k.textContent = get(x, "keys").toArray().slice(0, 2).join("  ");
      li.append(n, d, k); list.appendChild(li);
    });
  } else minibuf.hidden = true;

  // overlays
  const ov = get(v, "overlay");
  if (ov) {
    overlay.hidden = false;
    const kind = get(ov, "kind").name;
    overlay.querySelector("h2").textContent = kind === "outline" ? "Outline" : "Keys";
    const list = overlay.querySelector("ul");
    list.textContent = "";
    for (const it of get(ov, "items")) {
      const li = document.createElement("li");
      if (kind === "outline") {
        li.style.paddingLeft = (get(it, "level") - 1) * 1.1 + "rem";
        if (get(it, "todo")) { const t = document.createElement("span"); t.className = "todo"; t.textContent = get(it, "todo").toUpperCase(); li.appendChild(t); }
        li.appendChild(document.createTextNode(get(it, "title")));
        li.onclick = () => { dispatch(ev(K("type"), K("click"), K("pos"), R.vec(get(it, "row"), 0))); dispatch(ev(K("type"), K("key"), K("key"), "Escape")); };
      } else {
        const k = document.createElement("kbd"); k.textContent = get(it, "keys");
        const n = document.createElement("span"); n.className = "name"; n.textContent = get(it, "name");
        const d = document.createElement("span"); d.className = "doc"; d.textContent = get(it, "doc");
        li.append(k, n, d);
      }
      list.appendChild(li);
    }
  } else overlay.hidden = true;

  // scrollbar hint
  $("#scroll-hint").style.cssText = `top:${(top / Math.max(1, get(v, "total"))) * 100}%;height:${Math.max(4, (frag.length / Math.max(1, get(v, "total"))) * 100)}%`;
}

// grapheme column → x pixel offset within a row, measured from the DOM so
// proportional emoji/CJK widths are honest
const seg = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null;
function lineNode(row) { for (const n of view.children) if (n.dataset.row == row) return n; return null; }
function lineText(row) { const n = lineNode(row); return n ? n.textContent.replace(/\u200b/g, "").replace(/ ⋯$/, "") : ""; }
function lineLen(row) { const t = lineText(row); return seg ? [...seg.segment(t)].length : [...t].length; }
function xOf(row, col) {
  const node = lineNode(row);
  if (!node || col === 0) return 0;
  // walk text nodes to the UTF-16 offset of grapheme `col`
  const t = lineText(row);
  const gs = seg ? [...seg.segment(t)] : [...t].map((s, i) => ({ segment: s }));
  let u = 0; for (let i = 0; i < Math.min(col, gs.length); i++) u += gs[i].segment.length;
  if (col > gs.length) return xOf(row, gs.length) + (col - gs.length) * metrics.ch;
  const range = document.createRange();
  let acc = 0;
  const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
  let tn;
  while ((tn = walker.nextNode())) {
    if (tn.parentElement?.classList.contains("fold-mark")) continue;
    const len = tn.data.replace(/\u200b/g, "").length;
    if (acc + len >= u) {
      range.setStart(tn, Math.min(u - acc, tn.data.length));
      range.collapse(true);
      const r = range.getBoundingClientRect();
      return r.left - node.getBoundingClientRect().left;
    }
    acc += len;
  }
  return node.getBoundingClientRect().width;
}

// ─── input ─────────────────────────────────────────────────────────────────

const NAMED = new Set(["Escape", "Enter", "Backspace", "Tab", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "Delete", "PageUp", "PageDown"]);

function keyName(e) {
  let k = e.key;
  if (k === "Dead" || k === "Process" || k === "Unidentified") return null;
  const mods = (e.ctrlKey ? "C-" : "") + (e.altKey ? "M-" : "");
  if (NAMED.has(k)) return mods + (e.shiftKey && k === "Tab" ? "S-Tab" : k);
  if (k.length === 1 || [...k].length === 1) return mods + k;   // shift already applied by the layout
  return null;
}

let composing = false;
sink.addEventListener("compositionstart", () => { composing = true; });
sink.addEventListener("compositionend", (e) => {
  composing = false;
  if (e.data) dispatch(ev(K("type"), K("text"), K("text"), e.data));
  sink.value = "";
});
sink.addEventListener("keydown", (e) => {
  if (composing || e.isComposing) return;
  const k = keyName(e);
  if (k == null) return;
  // printable keys WITHOUT modifiers in insert/command modes arrive via `input`
  // (so IME and dead keys work); everything else is a command key
  const mode = document.body.dataset.mode;
  const textMode = mode === "insert" || mode === "command" || mode === "palette";
  if (textMode && k.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) return;
  if (e.metaKey) return;            // leave Cmd-shortcuts to the browser
  e.preventDefault();
  dispatch(ev(K("type"), K("key"), K("key"), k));
});
sink.addEventListener("input", (e) => {
  if (composing) return;
  const text = sink.value;
  sink.value = "";
  if (!text) return;
  const mode = document.body.dataset.mode;
  if (mode === "insert" || mode === "command" || mode === "palette") dispatch(ev(K("type"), K("text"), K("text"), text));
});
sink.addEventListener("paste", (e) => {
  const text = e.clipboardData?.getData("text/plain");
  if (text) { e.preventDefault(); dispatch(ev(K("type"), K("text"), K("text"), text)); }
});

$("#editor").addEventListener("mousedown", (e) => {
  const lineNode = e.target.closest(".line");
  if (!lineNode) { sink.focus(); return; }
  e.preventDefault();
  const row = Number(lineNode.dataset.row);
  const x = e.clientX - lineNode.getBoundingClientRect().left;
  let col = 0; const n = lineLen(row);
  while (col < n && xOf(row, col + 1) <= x + metrics.ch / 2) col++;
  dispatch(ev(K("type"), K("click"), K("pos"), R.vec(row, col), K("extend?"), e.shiftKey));
  sink.focus();
});
$("#editor").addEventListener("wheel", (e) => {
  e.preventDefault();
  const v = M.d_render(ed);
  const top = get(v, "top") + Math.sign(e.deltaY) * Math.max(1, Math.round(Math.abs(e.deltaY) / metrics.line));
  dispatch(ev(K("type"), K("scroll"), K("top"), Math.max(0, top)));
}, { passive: false });

function fitHeight() {
  const h = Math.floor($("#editor").clientHeight / metrics.line);
  dispatch(ev(K("type"), K("resize"), K("height"), h));
}
window.addEventListener("resize", fitHeight);
document.addEventListener("click", () => sink.focus());

// ─── boot ──────────────────────────────────────────────────────────────────

async function loadInitial() {
  const params = new URLSearchParams(location.search);
  const path = params.get("file");
  if (path) {
    try {
      const r = await fetch("/api/file?path=" + encodeURIComponent(path));
      if (r.ok) return { text: await r.text(), path };
    } catch (_) { /* fall through */ }
  }
  const r = await fetch("./welcome.bl.org");
  return { text: await r.text(), path: path || "welcome.bl.org" };
}

await document.fonts?.ready;
measure();
const { text, path } = await loadInitial();
ed = M.d_boot(text, path);
fitHeight();
sink.focus();
window.blEd = { dispatch, state: () => ed, render: () => M.d_render(ed), R, K };
