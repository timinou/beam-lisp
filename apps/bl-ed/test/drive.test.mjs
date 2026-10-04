// apps/bl-ed/test/drive.test.mjs — drive the COMPILED editor (BL → JS sync
// profile) with key sequences, headless, and assert on its state.
//   node --test apps/bl-ed/test/   (with BLED_OUT pointing at the JS build)
import { test } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { pathToFileURL } from "node:url";
import fs from "node:fs";

const out = path.resolve(process.env.BLED_OUT || "out/bl-ed");
// the `:` command line evaluates real Beam Lisp: start the in-page language
// (built into out/ by apps/bl-ed/build.sh) as the page host does
const { start } = await import(pathToFileURL(path.join(out, "repl.mjs")).href);
const repl = await start((f) => fs.readFileSync(path.join(out, "src", f), "utf8"));
globalThis.BL_HOST = Object.assign(globalThis.BL_HOST || {}, {
  "eval-ed": (src, api) => repl.evalWith(src, "ed", api),
});
const M = await import(pathToFileURL(path.join(out, "ed.main.mjs")).href);
const R = await import(pathToFileURL(path.join(out, "rt.mjs")).href);
const T = await import(pathToFileURL(path.join(out, "ed.text.mjs")).href);
const K = (s) => R.kw(s);
const get = (m, k) => m.get(K(k), null);

function boot(text) { return M.d_boot(text, "test.bl.org"); }
function key(ed, k) { return M.d_handle(ed, R.hashMap(K("type"), K("key"), K("key"), k)); }
/** Feed keys written as a space-separated list; `<sp>` is the space key. */
function keys(ed, seq) {
  for (const k of seq.split(" ")) ed = key(ed, k === "<sp>" ? " " : k);
  return ed;
}
function type(ed, s) { for (const ch of [...s]) ed = key(ed, ch); return ed; }
function text(ed) { return T.d_to_string(get(ed, "text")); }
function heads(ed) { return get(ed, "sels").toArray().map(s => get(s, "head").toArray()); }
function sel(ed) { const s = get(ed, "sels").nth(get(ed, "primary")); return [get(s, "anchor").toArray(), get(s, "head").toArray()]; }
function mode(ed) { return get(ed, "mode").name; }
function msg(ed) { return get(ed, "message"); }

const SAMPLE = [
  "#+TITLE: Drive",
  "",
  "* Alpha",
  "Some prose here.",
  "#+begin_src beam-lisp :id add",
  "(defn add [a b]",
  "  (+ a b))",
  "#+end_src",
  "** Beta :x:",
  "#+begin_src beam-lisp",
  "(def v [1 [2 3] {:k 4}])",
  "#+end_src",
  "* Gamma",
  "end",
].join("\n");

test("normal-mode motions: hjkl, w selects a word, counts", () => {
  let ed = boot(SAMPLE);
  ed = keys(ed, "j j j");
  assert.deepEqual(heads(ed), [[3, 0]]);
  ed = key(ed, "w");
  assert.deepEqual(sel(ed), [[3, 0], [3, 5]], "w selects from Some to the start of prose");
  ed = keys(ed, "2 w");
  // `.` is a WORD character here (Lisp: `ns.name`, `1.5`, `a.b/c` are one
  // word), so from `p`(3,5): w → `here.`(3,11), w → next line (4,0)
  assert.deepEqual(heads(ed), [[4, 0]], "a count repeats the motion");
  ed = keys(ed, "g g");
  assert.deepEqual(heads(ed), [[0, 0]]);
});

test("insert mode types, Escape returns, undo/redo round-trip", () => {
  let ed = boot("hello world");
  ed = keys(ed, "A");
  assert.equal(mode(ed), "insert");
  ed = type(ed, "!!");
  ed = key(ed, "Escape");
  assert.equal(text(ed), "hello world!!");
  assert.equal(mode(ed), "normal");
  ed = key(ed, "u");
  assert.equal(text(ed), "hello world", "one insert session is one undo step");
  ed = key(ed, "U");
  assert.equal(text(ed), "hello world!!");
});

test("multiple cursors: C adds a cursor below, typing goes to both", () => {
  let ed = boot("aaa\nbbb\nccc");
  ed = keys(ed, "C I");
  ed = type(ed, "> ");
  ed = key(ed, "Escape");
  assert.equal(text(ed), "> aaa\n> bbb\nccc");
});

test("x selects lines; d deletes and yanks; p pastes", () => {
  let ed = boot("one\ntwo\nthree");
  ed = keys(ed, "j x d");
  assert.equal(text(ed), "one\n\nthree");
  ed = keys(ed, "g g p");
  assert.ok(text(ed).startsWith("otwone") || text(ed).includes("two"), "the yanked line is pasted back");
});

test("org navigation: ]h [h g u ]b", () => {
  let ed = boot(SAMPLE);
  ed = keys(ed, "] h");
  assert.deepEqual(heads(ed), [[2, 0]], "first heading");
  ed = keys(ed, "] h");
  assert.deepEqual(heads(ed), [[8, 0]]);
  ed = keys(ed, "g u");
  assert.deepEqual(heads(ed), [[2, 0]], "parent of ** Beta is * Alpha");
  ed = keys(ed, "] b");
  assert.deepEqual(heads(ed), [[4, 0]], "next block");
  ed = keys(ed, "] b ] b");
  assert.equal(msg(ed), "No later block");
});

test("structural form motion inside a cell", () => {
  let ed = boot(SAMPLE);
  ed = keys(ed, "5 j");                // row 5: (defn add [a b]
  assert.deepEqual(heads(ed), [[5, 0]]);
  ed = keys(ed, "m m");               // select the form under the cursor: the whole defn
  assert.deepEqual(sel(ed), [[5, 0], [6, 9]]);
  ed = keys(ed, "g j");               // down: first child = `defn`
  assert.deepEqual(sel(ed), [[5, 1], [5, 4]]);
  ed = keys(ed, "g L g L");           // next, next: `add`, then `[a b]`
  assert.deepEqual(sel(ed), [[5, 10], [5, 14]]);
  ed = keys(ed, "g k");               // up: back to the defn
  assert.deepEqual(sel(ed), [[5, 0], [6, 9]]);
});

test("paredit-style: wrap and raise", () => {
  let ed = boot("#+begin_src beam-lisp\n(f (g x))\n#+end_src");
  ed = keys(ed, "j 4 l");              // on `g`
  ed = keys(ed, "<sp> r");             // raise `g` over (g x)
  assert.equal(text(ed).split("\n")[1], "(f g)");
  ed = keys(ed, "<sp> w (");           // wrap g in ( ) and insert
  ed = key(ed, "Escape");
  assert.equal(text(ed).split("\n")[1], "(f (g))");
});

test("the command line evaluates Beam Lisp against the live editor", () => {
  let ed = boot(SAMPLE);
  ed = key(ed, ":");
  assert.equal(mode(ed), "command");
  ed = type(ed, "(count (ed/outline))");
  ed = key(ed, "Enter");
  assert.equal(msg(ed), "3");
  ed = key(ed, ":");
  ed = type(ed, '(ed/bind :normal "Q" :doc-end)');
  ed = key(ed, "Enter");
  ed = key(ed, "Q");
  assert.deepEqual(heads(ed), [[13, 0]], "a key bound from the command line works");
  ed = key(ed, ":");
  ed = type(ed, "(ed/goto 5)");
  ed = key(ed, "Enter");
  assert.deepEqual(heads(ed), [[4, 0]]);
});

test("the command line is the real language: macros, defn, destructuring, threading", () => {
  let ed = boot(SAMPLE);
  const run = (src) => { ed = key(ed, ":"); ed = type(ed, src); ed = key(ed, "Enter"); return msg(ed); };
  assert.match(run("(defmacro twice [x] `(do ~x ~x))"), /\$macro/, "a macro defined from the command line");
  assert.equal(run("(defn deepest [] (->> (ed/outline) (map first) (reduce max)))").startsWith("#<fn"), true);
  assert.equal(run("(deepest)"), "2", "a user fn over the live outline");
  assert.equal(run("(let [[[lvl title row]] (ed/outline)] (str title \"@\" row))"), '"Alpha@3"');
  assert.equal(run("(twice (ed/goto 9))"), "nil");
  assert.deepEqual(heads(ed), [[8, 0]], "a user macro drove the editor");
  assert.match(run("(undefined-thing)"), /^error: undefined var/);
});

test("the palette finds and runs commands by fuzzy name", () => {
  let ed = boot(SAMPLE);
  ed = keys(ed, "<sp> <sp>");
  assert.equal(mode(ed), "palette");
  ed = type(ed, "headnext");
  const view = M.d_render(ed);
  const matches = get(get(view, "minibuf"), "matches").toArray().map(m => get(m, "name"));
  assert.ok(matches.includes("heading-next"), "fuzzy match: " + matches.join(","));
  ed = key(ed, "Enter");
  assert.deepEqual(heads(ed), [[2, 0]]);
});

test("describe-key explains a binding", () => {
  let ed = boot("x");
  ed = keys(ed, "<sp> k");
  ed = keys(ed, "] h");
  assert.match(msg(ed), /\] h runs :heading-next/);
});

test("search: / n N * with smart-case and wrap", () => {
  let ed = boot("alpha beta\nGamma alpha\nbeta ALPHA");
  ed = key(ed, "/");
  ed = type(ed, "alpha");
  ed = key(ed, "Enter");
  assert.deepEqual(sel(ed), [[1, 6], [1, 10]], "first match after the cursor");
  ed = key(ed, "n");
  assert.deepEqual(sel(ed), [[2, 5], [2, 9]], "lowercase needle matches ALPHA");
  ed = key(ed, "n");
  assert.deepEqual(sel(ed), [[0, 0], [0, 4]], "wraps to the top");
  assert.match(msg(ed), /wrapped/);
  ed = key(ed, "N");
  assert.deepEqual(sel(ed), [[2, 5], [2, 9]], "N goes back, wrapping");
  ed = key(ed, "/"); ed = type(ed, "ALPHA"); ed = key(ed, "Enter");
  assert.deepEqual(sel(ed), [[2, 5], [2, 9]], "an uppercase needle is case-sensitive");
  ed = keys(ed, "g g w *");
  assert.deepEqual(sel(ed), [[2, 0], [2, 3]], "* searches the word under the cursor (beta)");
});

test("dirty is derived: an edit dirties, undo back to the saved text cleans, a save at the current rev cleans", () => {
  const dirty = (ed) => get(get(M.d_render(ed), "status"), "dirty?");
  let ed = boot("abc");
  assert.equal(dirty(ed), false);
  ed = keys(ed, "A"); ed = type(ed, "d"); ed = key(ed, "Escape");
  assert.equal(dirty(ed), true);
  ed = key(ed, "u");
  assert.equal(dirty(ed), false, "undo to the loaded text is clean");
  ed = key(ed, "U");
  const rev = get(ed, "rev");
  ed = M.d_handle(ed, R.hashMap(K("type"), K("saved"), K("rev"), rev, K("ok?"), true, K("message"), ""));
  assert.equal(dirty(ed), false, "saved at the current revision");
  ed = key(ed, "u");
  assert.equal(dirty(ed), true, "undo past the save is dirty again");
});

test("save is an effect, not a side effect", () => {
  let ed = boot("a");
  ed = type(ed, "ib");
  ed = key(ed, "Escape");
  ed = key(ed, "C-s");
  const [ed2, effects] = M.d_take_effects(ed).toArray();
  const e = effects.toArray()[0];
  assert.equal(get(e, "kind").name, "save");
  assert.equal(get(e, "text"), "ba");
  assert.equal(get(ed2, "effects").cnt, 0);
});

test("an eval reload keeps the cursor and is one undo step", () => {
  let ed = boot("#+begin_src beam-lisp :id a\n(+ 1 2)\n#+end_src");
  ed = keys(ed, "j l l");
  const before = heads(ed);
  const withResults = "#+begin_src beam-lisp :id a\n(+ 1 2)\n#+end_src\n#+RESULTS: a\n: 3\n";
  ed = M.d_handle(ed, R.hashMap(K("type"), K("load"), K("text"), withResults, K("path"), "t"));
  assert.equal(text(ed), withResults);
  assert.deepEqual(heads(ed), before, "the cursor stays where it was");
  ed = key(ed, "u");
  assert.equal(text(ed), "#+begin_src beam-lisp :id a\n(+ 1 2)\n#+end_src", "undo removes the results");
});

test("render model: segments, problems, status", () => {
  let ed = boot("#+begin_src beam-lisp\n(f [x)\n#+end_src");
  ed = key(ed, "j");
  const v = M.d_render(ed);
  const line1 = get(v, "lines").nth(1);
  const kinds = get(line1, "segments").toArray().map(s => get(s, "kind").name);
  assert.ok(kinds.includes("error"), "a mismatched closer renders as an error: " + kinds);
  assert.equal(get(get(v, "status"), "problems"), 2);
});

test("incremental structure == full derive, over random typing in real documents", async () => {
  const C = await import(pathToFileURL(path.join(out, "ed.core.mjs")).href);
  const root = path.resolve(process.env.BLED_ROOT || ".");
  const docs = ["docs/tools/02-lsp.bl.org", "docs/changelog/v2026.4.bl.org", "docs/split/01-how-one-file-becomes-two-programs.bl.org"]
    .map(p => path.join(root, p)).filter(p => fs.existsSync(p));
  let s = 12345; const rnd = () => ((s = (Math.imul(s, 1103515245) + 12345) >>> 0) / 4294967296);
  const chars = ["a", " ", "(", ")", "\"", "*", "#", "\n", "x", ";", "[", "]"];
  let checks = 0;
  for (const f of docs) {
    let ed = boot(fs.readFileSync(f, "utf8"));
    const nLines = () => get(get(ed, "text"), "lines").cnt;
    for (let step = 0; step < 150; step++) {
      const r = Math.floor(rnd() * nLines());
      ed = M.d_handle(ed, R.hashMap(K("type"), K("click"), K("pos"), R.vec(r, Math.floor(rnd() * 40))));
      ed = key(ed, "i");
      ed = M.d_handle(ed, R.hashMap(K("type"), K("text"), K("text"), chars[Math.floor(rnd() * chars.length)]));
      ed = key(ed, "Escape");
      const full = C.d_derive_structure(ed);
      assert.ok(R.eqv(get(ed, "struct"), get(full, "struct")), `struct diverged at step ${step} in ${f}`);
      assert.ok(R.eqv(get(ed, "forms"), get(full, "forms")), `forms diverged at step ${step} in ${f}`);
      checks++;
    }
  }
  assert.ok(checks >= 300, "ran " + checks);
});

test("round trip: every repo .bl.org is reproduced byte-for-byte", () => {
  const root = path.resolve(process.env.BLED_ROOT || ".");
  const files = [];
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else if (p.endsWith(".bl.org")) files.push(p); } };
  for (const d of ["docs", "examples"]) if (fs.existsSync(path.join(root, d))) walk(path.join(root, d));
  assert.ok(files.length > 10, "found " + files.length + " files");
  for (const f of files) {
    const s = fs.readFileSync(f, "utf8");
    const ed = boot(s);
    assert.equal(text(ed), s, f);
    // the span partition covers every line exactly once
    const bs = get(get(ed, "struct"), "blocks").toArray();
    const covered = bs.reduce((n, b) => n + (get(b, "to") - get(b, "from")), 0);
    assert.equal(covered, s.split("\n").length, "partition of " + f);
  }
});
