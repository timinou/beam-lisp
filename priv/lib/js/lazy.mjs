// priv/lib/js/lazy.mjs — `BeamLisp.LazySeq` (and its value-shaped sibling
// `BeamLisp.Deferred`/`Delay`) for JavaScript: the lazy node, its cell state
// machine, and the leaf ABI rt.bl calls (PLAN-163 U2).
//
// THE SAME MACHINE AS THE BEAM, MINUS WHAT ONLY THE BEAM NEEDS. A node's cell
// is in one of the BEAM's five states (priv/host/lazy_seq.bl):
//
//   [PENDING thunk recipe?] ─claim→ [RUNNING attempt] ─complete→ [COMPLETED v]
//         ▲                               │           ─fail────→ [FAILED thunk kind reason stack]
//         └──────── release (halt) ───────┘           ─terminal→ [TERMINAL reason]
//
// On the BEAM the cell lives off-heap in a NIF, so processes can share it, and
// every transition is a versioned compare-and-swap with waiters, owner
// monitoring and a cache budget. A page is ONE thread: nothing else runs while
// a thunk runs, so there are no waiters, no lost owners, no versions and no
// off-heap bytes to bound — the cell is a field. What stays is every answer a
// program can SEE, measured on the BEAM (2026-10-04, ~/tmp/bljs/sh/lazyprobe.bl):
//
//   * realise once: a thunk runs at most once per successful node, whether the
//     node is walked (`first`) or folded (`reduce` claims the fold recipe);
//   * a thrown thunk leaves the node FAILED and RETRIABLE — the next force runs
//     it again — and re-raises the thunk's own error unchanged;
//   * a thunk that forces its own node is TERMINAL `:recursive_force`, for
//     that force and every later one;
//   * a node whose COMPLETED value would contain itself is TERMINAL
//     `:cyclic_memo` (the NIF's cycle guard: `(def s (lazy-seq (cons 1 s)))`);
//   * a halted fold publishes nothing and hands the node back PENDING;
//   * a lazy-seq body may return any seqable; the HEAD is normalized, the tail
//     stays lazy; 100001 nested empty thunks is the realize-depth error.
//
// The ABI (`LEAVES` below) is the BEAM's, name for name and shape for shape:
// `claim_recipe` answers `{:claimed attempt pending}` or nil, `capture_attempt`
// `{:ok v}` or `{:failed kind reason stack}`, `cell` nil or a list cell.

// rt.mjs imports THIS module (printing and `=` force a lazy seq), and this one
// imports rt.mjs: an import cycle, legal because NOTHING here touches an rt
// binding at load time — every `R.x` below is read when a function runs.
import * as R from "./rt.mjs";

const kw = (s) => R.kw(s);
const T = (...xs) => new R.Tup(xs);
const PENDING = 0, RUNNING = 1, COMPLETED = 2, FAILED = 3, TERMINAL = 4;
const K = new Proxy({}, { get: (_, n) => R.kw(n) });   // K.ok → :ok, at call time
export const CHUNK = 32;

/** The shared native memo resource (the BEAM struct's `:resource`): ONE per
    logical node, however many metadata-carrying `LazySeq` values reference it.
    Holds the cell state `s` (an array, tag first) and the cycle-guard `edges`,
    so a transition or an edge recorded through one alias is seen through every
    other. `with-meta` is an immutable update of the VALUE; the resource is the
    identity, exactly as `BeamLisp.Meta/with_meta` shares the struct's
    `:resource` (priv/host/meta.bl). */
class Memo {
  constructor(thunk, recipe) {
    this.s = recipe ? [PENDING, thunk, recipe] : [PENDING, thunk];
    this.edges = null;
  }
}

/** A lazy node. `meta` is the VALUE-owned metadata (the BEAM struct's
    `:metadata`); `memo` is the shared cell state + cycle edges. `s`/`edges`
    read and write through the memo, so aliases of one node never diverge. */
export class LazySeq {
  constructor(thunk, recipe, meta, memo) {
    this.memo = memo === undefined ? new Memo(thunk, recipe) : memo;
    this.meta = meta === undefined ? null : meta;
  }
  get s() { return this.memo.s; }
  set s(v) { this.memo.s = v; }
  get edges() { return this.memo.edges; }
  set edges(v) { this.memo.edges = v; }
}
const isLazy = (x) => x instanceof LazySeq;

/** `ForceError`: the refusal every force failure other than the thunk's own
    error is reported as — "LazySeq force failed: <inspect reason>". */
export class ForceError extends Error {
  constructor(reason) {
    super("LazySeq force failed: " + R.printStr(reason));
    this.reason = reason;
    this.data = null;                       // (ex-data e) is nil on the BEAM
    this.blType = kw("Elixir.BeamLisp.LazySeq.ForceError");
  }
}
const forceError = (reason) => { throw new ForceError(reason); };

// ─── the raw failure: what `catch-raw` records and `erlang:raise/3` replays ──
// A JS throw is already the exact value: the error object IS kind + reason +
// stack. Recording it and re-throwing the SAME object replays it bit for bit.
const KIND = (e) => (e instanceof Error ? K.error : K.throw);
export function raise(kind, reason, _stack) { throw reason; }

// ─── forcing ───────────────────────────────────────────────────────────────

/** Force a node to its value: the published answer, the thunk's own failure
    replayed, or `ForceError`. */
export function force(l) {
  const s = l.s;
  switch (s[0]) {
    case COMPLETED: return s[1];
    case TERMINAL: return forceError(s[1]);
    case RUNNING: l.s = [TERMINAL, kw("recursive_force")]; return forceError(kw("recursive_force"));
    default: {                                  // PENDING or FAILED: run the thunk
      const thunk = s[1];
      l.s = [RUNNING, {}];
      let v;
      try { v = thunk(); }
      catch (e) {
        // a recursive force inside the thunk already made the node terminal:
        // that verdict stands (the BEAM publishes it before the thunk returns)
        if (l.s[0] === TERMINAL) throw e;
        l.s = [FAILED, thunk, KIND(e), e, null];
        throw e;
      }
      if (l.s[0] === TERMINAL) return forceError(l.s[1]);
      if (reaches(v, l)) { l.s = [TERMINAL, kw("cyclic_memo")]; return forceError(kw("cyclic_memo")); }
      l.s = [COMPLETED, v];
      return v;
    }
  }
}

/** The cycle guard, as the NIF keeps it (native/lazy_memo would_cycle): each
    node has EDGES — the native memo resources its published value reaches
    directly (the walk stops AT a lazy node: that node's own edges are the
    graph beyond it). Publishing `v` into `node` is a cycle when `node`'s memo
    is reachable from `v`'s edges through the edge graph. Edges are the MEMO,
    not the LazySeq value, so an alias added by `with-meta` is the same node.
    Edges are found by walking `v` only down to its first lazy nodes, so a long
    realised seq costs O(new cells) per publish, not a re-walk of everything
    behind it. */
function directEdges(v) {
  // the NIF's pre-check (lazy_memo.bl dependencies): a scalar, or a proper
  // list of scalars (a produced chunk), cannot reach a node — no walk
  if (v === null || typeof v !== "object") return NO_EDGES;
  if (v instanceof R.Cons) {
    let p = v;
    while (p instanceof R.Cons && (p.h === null || typeof p.h !== "object")) p = p.t;
    if (p === R.EMPTY) return NO_EDGES;
    // a produced chunk with a lazy tail — the shape of nearly every publish:
    // the walk would stop AT that node, so it is the one edge
    if (p instanceof LazySeq) return [p.memo];
  }
  const out = [];
  const seen = new Set();
  const stack = [v];
  while (stack.length) {
    const x = stack.pop();
    if (x === null || typeof x !== "object" || seen.has(x)) continue;
    seen.add(x);
    if (x instanceof LazySeq) { if (!seen.has(x.memo)) out.push(x.memo); continue; }
    if (x instanceof R.Cons) { stack.push(x.h, x.t); continue; }
    if (x instanceof R.Tup) { for (const e of x.items) stack.push(e); continue; }
    if (x instanceof R.Vec) { for (const e of x) stack.push(e); continue; }
    if (x instanceof R.HMap) { for (const [k, w] of x.entries()) stack.push(k, w); continue; }
    if (x instanceof R.HSet) { for (const e of x) stack.push(e); continue; }
  }
  return out;
}
const NO_EDGES = [];
/** Would publishing a value whose edges are the memos `deps` into `node`
    close a cycle? Node identity is the MEMO, so an alias is the same node. */
function wouldCycle(node, deps) {
  if (deps.length === 0) return false;
  const target = node.memo;
  if (deps.length === 1 && deps[0] !== target && !deps[0].edges) return false;
  const seen = new Set();
  const stack = deps.slice();
  while (stack.length) {
    const d = stack.pop();
    if (d === target) return true;
    if (seen.has(d)) continue;
    seen.add(d);
    if (d.edges) for (const e of d.edges) stack.push(e);
  }
  return false;
}
/** Publish-time check + edge record; true when it would cycle. */
function reaches(v, node) {
  const deps = directEdges(v);
  if (wouldCycle(node, deps)) return true;
  if (deps.length) node.edges = deps;
  return false;
}

/** `memo_state`: the logical state, as the BEAM reports it (`Deferred`'s
    `realized?` reads only the `:completed` tag). */
export function memoState(l) {
  const s = l.s;
  switch (s[0]) {
    case PENDING: return s.length === 3 ? T(K.pending, s[1], s[2]) : T(K.pending, s[1]);
    case RUNNING: return T(K.running, null, null, s[1], R.EMPTY);
    case COMPLETED: return T(K.completed, s[1]);
    case FAILED: return T(K.failed, s[1], s[2], s[3], s[4]);
    default: return T(K.terminal, s[1]);
  }
}

// ─── normalizing to a cell ─────────────────────────────────────────────────
// `cell` is the one chokepoint every walk goes through: nil, a list cell whose
// tail may be another node, or (for a non-seqable) the value itself.

function normalizeList(xs) { return xs === R.EMPTY ? null : xs; }

/** Force + normalize the head, peeling nested nodes (the BEAM's realize_step). */
export function realize(l) {
  let node = l;
  for (let depth = 0; ; depth++) {
    if (depth > 100000) throw new R.BLError("LazySeq.realize: thunk chain " + depth + " deep without a head — a self-referential lazy seq never produces a cell; it would hang forever");
    const v = force(node);
    if (v === null || v === undefined || v === R.EMPTY) return null;
    if (v instanceof LazySeq) { node = v; continue; }
    return headCell(v);
  }
}

/** A forced value as a cell. Lists stay; vectors and sets become their
    element lists; anything else is the BEAM's answer for it (a string or a map
    in a lazy-seq body is a `badarg` there: `cell` hands it back unchanged and
    `hd` refuses it). */
function headCell(v) {
  if (v instanceof R.Cons) return v;
  if (v instanceof R.Vec) return normalizeList(v.toList());
  if (v instanceof R.HSet) return normalizeList(R.listFromArray([...v]));
  if (v instanceof SeqCursor) return v.cell();
  return v;
}

/** Any seqable to a realized cell (BeamLisp.LazySeq/cell). */
// The host's Enumerable protocol owns generic input coercion (maps and
// grapheme strings); a lazy thunk's VALUE still follows headCell's contract.
let enumerableCell = (x) => x;
export function bindEnumerableCell(f) { enumerableCell = f; }
export function cell(x) {
  if (x === null || x === undefined || x === R.EMPTY) return null;
  if (x instanceof LazySeq) return realize(x);
  if (x instanceof SeqCursor) return x.cell();
  if (x instanceof R.Cons) return x;
  if (x instanceof R.Vec) return normalizeList(x.toList());
  if (x instanceof R.HSet) return normalizeList(R.listFromArray([...x]));
  return enumerableCell(x);
}

// ─── constructors ──────────────────────────────────────────────────────────

const fnArity = (f) => (typeof f === "function" ? f.length : -1);
function clauseError(fn, arity) {
  const e = new R.BLError("no function clause matching in BeamLisp.LazySeq." + fn + "/" + arity);
  e.blType = kw("Elixir.FunctionClauseError");
  throw e;
}
export function newLazy(thunk, recipe) {
  if (typeof thunk !== "function") clauseError("new", recipe === undefined ? 1 : 2);
  if (recipe !== undefined && typeof recipe !== "function") clauseError("new", 2);
  return new LazySeq(thunk, recipe);
}

/** Prepend `elems` to a node produced by `tailFn`: one shared tail node, each
    element a cons onto it. Empty `elems` → nil. */
export function chain(elems, tailFn) {
  if (elems === R.EMPTY || elems === null) return null;
  if (typeof tailFn !== "function") clauseError("chain", 2);
  const xs = []; for (let p = elems; p instanceof R.Cons; p = p.t) xs.push(p.h);
  let r = new LazySeq(tailFn);
  for (let i = xs.length - 1; i >= 0; i--) r = new R.Cons(xs[i], r);
  return r;
}
/** `with_meta` on a lazy node (the owning host primitive, priv/host/meta.bl's
    `BeamLisp.Meta/with_meta`): the SAME native memo resource under a NEW
    value-owned metadata map. The original keeps its metadata; both values share
    the cell state and the cycle edges, so realization, retry and the cycle
    guard are the node's, never a per-metadata copy. */
export function withMeta(l, m) {
  if (!(l instanceof LazySeq)) throw new R.BLError("with-meta: " + R.printStr(l) + " cannot carry metadata");
  return new LazySeq(null, null, m === undefined ? null : m, l.memo);
}

/** A finite list walked a chunk at a time: on the BEAM the list is copied once
    off-heap; here it is the list itself, walked in place. A cell is the BEAM's
    shape exactly — `[head | cursor']`, the TAIL a sub-cursor, never the bare
    rest of the list (rt.bl walks `(SeqCursor/cell (tl cell))`). nil at the end. */
export class SeqCursor {
  constructor(list) { this.l = list; }
  cell() { const l = this.l; return l instanceof R.Cons ? new R.Cons(l.h, new SeqCursor(l.t)) : null; }
}

/** Normalize a producer input (BeamLisp.LazySeq/input): a vector is unwrapped,
    a list longer than one chunk becomes a cursor, anything else is itself. */
export function input(x) {
  if (x instanceof R.Vec) return input(x.toList());
  // Only a PROPER finite list longer than one chunk becomes a finite cursor,
  // exactly as the BEAM's `(erlang/is_list x)` guard plus `length > 32` do:
  // a Cons carries its proper length in `n` (`-1` when the chain ends in
  // anything but `()` — a lazy tail, a cursor, a scalar), so this is O(1) and
  // never forces a tail. An improper chain is returned unchanged: the walk
  // decides (and a genuinely malformed tail still refuses downstream).
  if (x instanceof R.Cons && x.n > CHUNK) return new SeqCursor(x);
  return x;
}

// ─── the fold recipe: claim / complete / fail / release ────────────────────

/** Claim the node's pending fold recipe: `{:claimed attempt pending}`, or nil
    when there is nothing to claim (not lazy, no recipe, not pending). */
export function claimRecipe(l) {
  if (!(l instanceof LazySeq)) return null;
  const s = l.s;
  if (s[0] !== PENDING || s.length !== 3) return null;
  const attempt = {};
  const pending = T(K.pending, s[1], s[2]);
  l.s = [RUNNING, attempt];
  return T(K.claimed, attempt, pending);
}
const ownedBy = (l, attempt) => l.s[0] === RUNNING && l.s[1] === attempt;

/** Run `thunk` → `{:ok v}` | `{:failed kind reason stack}` (catch-raw). */
export function captureAttempt(thunk) {
  try { return T(K.ok, thunk()); }
  catch (e) { return T(K.failed, KIND(e), e, null); }
}

/** Publish the complete element list a claimed fold produced. */
export function completeAttempt(l, attempt, elems) {
  if (ownedBy(l, attempt)) {
    const v = elems === R.EMPTY ? null : elems;
    if (reaches(v, l)) { l.s = [TERMINAL, kw("cyclic_memo")]; return forceError(kw("cyclic_memo")); }
    l.s = [COMPLETED, v];
    return K.ok;
  }
  if (l.s[0] === TERMINAL) return forceError(l.s[1]);
  return forceError(T(kw("stale_force_owner"), attempt));
}

/** Publish a claimed fold's failure against the ORIGINAL thunk (retriable) and
    re-raise it. Never returns. */
export function failAttempt(l, attempt, thunk, kind, reason, stack) {
  if (ownedBy(l, attempt)) l.s = [FAILED, thunk, kind, reason, stack];
  throw reason;
}

/** Hand a claimed fold back unpublished (the halt path): restore `pending`. */
export function releaseRecipe(l, attempt, pending) {
  if (ownedBy(l, attempt)) { l.s = [PENDING, ...pending.items.slice(1)]; return K.ok; }
  if (l.s[0] === TERMINAL) return T(K.terminal, l.s[1]);
  return forceError(T(kw("stale_force_owner"), attempt));
}

// ─── walks over a whole seq (iterative: a 100k doall cannot blow the stack) ──

export function toList(x) {
  const out = [];
  for (let c = cell(x); c !== null; c = cell(c.t)) {
    if (!(c instanceof R.Cons)) throw new R.BLError("errors were found at the given arguments: not a list cell " + R.printStr(c));
    out.push(c.h);
  }
  return R.listFromArray(out);
}
export function count(x) { let n = 0; for (let c = cell(x); c !== null; c = cell(c.t)) n++; return n; }
export function run(x) { for (let c = cell(x); c !== null; c = cell(c.t)); return K.ok; }
export function prefix(x, n) {
  const out = [];
  for (let c = cell(x); c !== null && out.length < n; c = cell(c.t)) out.push(c.h);
  return R.listFromArray(out);
}
/** `{taken truncated?}`: up to `n` elements, and whether more remain. */
export function sample(x, n) {
  const p = []; for (let c = cell(x); c !== null && p.length < n + 1; c = cell(c.t)) p.push(c.h);
  return p.length > n ? T(R.listFromArray(p.slice(0, n)), true) : T(R.listFromArray(p), false);
}

// ─── Deferred / Delay: `delay`, `force`, `realized?`, `delay?` ──────────────

export class Delay { constructor(seq) { this.seq = seq; } }
export function delay(thunk) {
  if (typeof thunk !== "function") { const e = new R.BLError("no function clause matching in BeamLisp.Deferred.delay/1"); e.blType = kw("Elixir.FunctionClauseError"); throw e; }
  return new Delay(new LazySeq(thunk));
}
export const deferredForce = (x) => (x instanceof Delay ? force(x.seq) : x);
export const deferredRealized = (x) => (x instanceof Delay ? x.seq.s[0] === COMPLETED : true);
export const isDelay = (x) => x instanceof Delay;

// ─── `distinct`'s memory: a mutable membership set (LazyMemo/seen) ──────────
export class Seen { constructor() { this.m = new Map(); } }
export function seenAdmit(s, keys) {
  const out = [];
  for (let p = keys; p instanceof R.Cons; p = p.t) {
    const k = R.printStr(p.h);          // hash_key'd terms: printed form is the identity
    if (s.m.has(k)) out.push(false); else { s.m.set(k, true); out.push(true); }
  }
  return R.listFromArray(out);
}

// ─── the leaf table (merged into leaves.mjs) ───────────────────────────────

const LS = "Elixir.BeamLisp.LazySeq/";
export const LAZY_LEAVES = {
  [LS + "lazy?/1"]: isLazy,
  [LS + "chunk_size/0"]: () => CHUNK,
  [LS + "new/1"]: (t) => newLazy(t),
  [LS + "new/2"]: (t, r) => newLazy(t, r),
  [LS + "from_fun/1"]: (t) => newLazy(t),
  [LS + "input/1"]: input,
  [LS + "chain/2"]: chain,
  [LS + "cell/1"]: cell,
  [LS + "force/1"]: force,
  [LS + "realize/1"]: realize,
  [LS + "memo_state/1"]: memoState,
  [LS + "pending?/1"]: (l) => l.s[0] === PENDING,
  [LS + "claim_recipe/1"]: claimRecipe,
  [LS + "capture_attempt/1"]: captureAttempt,
  [LS + "complete_attempt/3"]: completeAttempt,
  [LS + "fail_attempt/6"]: failAttempt,
  [LS + "release_recipe/3"]: releaseRecipe,
  [LS + "to_list/1"]: toList,
  [LS + "count/1"]: count,
  [LS + "run/1"]: run,
  [LS + "prefix/2"]: prefix,
  [LS + "sample/2"]: sample,
  [LS + "nth/2"]: (x, i) => { let k = i; for (let c = cell(x); c !== null; c = cell(c.t), k--) if (k === 0) return c.h; return null; },
  "Elixir.BeamLisp.SeqCursor/new/1": (l) => new SeqCursor(l),
  "Elixir.BeamLisp.SeqCursor/cell/1": (c) => c.cell(),
  "Elixir.BeamLisp.LazyMemo/seen/0": () => new Seen(),
  "Elixir.BeamLisp.LazyMemo/seen_admit/2": seenAdmit,
  "Elixir.BeamLisp.Deferred/delay/1": delay,
  "Elixir.BeamLisp.Deferred/force/1": deferredForce,
  "Elixir.BeamLisp.Deferred/realized?/1": deferredRealized,
  "Elixir.BeamLisp.Deferred/delay?/1": isDelay,
};
