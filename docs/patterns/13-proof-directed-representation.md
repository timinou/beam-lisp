# 13 — Proof-directed representation

*When the patterns over a value are all rigid over one shape, the value can
take that shape: tuples for fixed records, unboxed fields across calls, no
`match_fail`, exactly as much laziness as the pattern demands, and the
BEAM's own selective-receive optimisation.*

## The move

Capsules 10–12 chose *code* by proof. This capsule chooses *data*. The
principle: a value's representation is invisible to the program if every
operation on it is one the compiler emitted — and the compiler emitted
them from patterns it can see. So:

```
∀ sites s reading value v:  pattern(s) rigid over shape S
⟹ represent v as S natively
```

Each instance below names the proof, the representation, and the
obligation.

## 1. Fixed shape ⇒ tuple, not map

**Proof**: `system.core/state-shape` (exists) says a server's state is
always `{:count int :log vector}` — every clause binds it with `{:keys
[count log]}` and every reply constructs it with the same two keys.
**Representation**: `{Count, Log}` — a 2-tuple; field reads are `element/2`
(one instruction) instead of `map_get` (a hash lookup); construction is a
tuple literal (2 words + header) instead of a small map (keys tuple + values).
**Obligation**: every op on `state` is a pattern read or a full construct —
no `assoc` of an unknown key, no `keys`, no passing `state` to a function
outside the proven set. `footprint` gives the ops; if any escapes, keep the
map.
**Exposure**: `(map? state)` inside the server would answer false. The
obligation includes "no reflection on `state`" — reflective ops are ops.

## 2. Unboxed arguments across calls

**Proof**: callee `g` has one clause `[[a b]]` (rigid 2-vector) and every
caller (from `codebase`) constructs the argument as a literal `[x y]`.
**Representation**: a *worker* `g'/2` taking `A, B` directly; `g/1` becomes a
wrapper that destructures and calls `g'`. Callers proven to pass a literal
call `g'` directly — no vector allocated, no pattern run. (GHC's
worker/wrapper transformation; here gated by pattern rigidity instead of
strictness analysis.)
**Obligation**: `g'` is only called from sites where the vector would have
been built and immediately destructured; `g/1` stays for every other caller
and for the fn *value* (`(map g xs)`).

## 3. Proven-exhaustive ⇒ no `match_fail`

**Proof**: capsule 12's tree has no `match_fail` path over the domain
`typed` gives the argument.
**Representation**: the fallthrough clause is deleted. Erlang's compiler
then also drops the `function_clause` error-construction code and the
`case` becomes a pure jump table.
**Obligation**: none beyond the tree's own — but the *domain* assumption is
now load-bearing: if a caller outside `typed`'s view passes an unexpected
value, the failure is a `case_clause` deeper in, with a worse message. So:
keep the fallthrough for *exported* fns; drop it for `defn-` private ones
whose callers are all in the namespace (`codebase` knows).

## 4. Static realization depth

**Proof**: the pattern `[a b & _]` reads indices 0 and 1 and never the rest
(the `& _` binds nothing; normal form has no `(:rest)` bind).
**Representation**: on a `LazySeq` argument, realize exactly two cells
(`LazySeq.cell` twice), never `to_list`. Today `RT.nth` already does this
per index; the gain is that the compiler *knows* the depth is 2 and can emit
two `cell` calls in sequence with no loop, and — more importantly —
`footprint` can record "realizes ≤ 2" as a fact, so passing an infinite seq
here is proven safe.
**Obligation**: `D`'s realization count equals `L`'s (capsule 03 counts
realization as an observation).

## 5. Selective receive, the way the BEAM wants it

The BEAM optimises `Ref = make_ref(), …, receive {Ref, Reply} -> … end`:
since OTP 24 the compiler emits `recv_mark`/`recv_set` so the receive skips
every message that arrived *before* the ref was made — turning O(mailbox)
into O(1) for request/reply. **It only fires when the compiler can see the
`make_ref` and the pattern using it in the same function.**
**Proof**: pattern in `receive` binds a position to a local that was bound
from `(erlang/make_ref)` (or `(make-ref)`) in the same fn body, with no
intervening receive.
**Representation**: emit the Core the optimisation recognises (a plain
`receive` with the ref variable in the pattern head — *not* a `RT.nth` step
after a catch-all `receive`, which is what a lenient vector pattern would
produce today). Owning the lowering is what makes this reachable at all.
**Obligation**: same messages match; the mark/set only skips messages that
could not match anyway (that is the VM's guarantee, not ours).

## 6. Small-arity vectors as tuples in the *pattern* only

Even before capsule 01's one-body vector lands, the pattern layer can treat
`%Vector{items: T}` with `tuple_size(T) =:= n` as the rigid case and fall
through otherwise — the trie body just takes the step path. This is the
representation-agnostic *reading* of a vector, and it is what the obligation
forces (capsule 03, "domain closure").

## Where each proof comes from

| representation | proof source | exists today |
|---|---|---|
| tuple state | `system.core/state-shape` + `footprint` ops | yes / yes |
| unboxed args | `codebase` call sites + clause normal form | yes / capsule 02 |
| no `match_fail` | `match.bl` tree + `typed` domain | capsule 12 / yes |
| realization depth | normal form `(:rest)` presence | capsule 02 |
| selective receive | `codebase` def-use of `make_ref` in fn | yes (facts), needs the query |

## Sketch

- Each is a *rewrite* over the compiler's clause list or the emitted
  Core, guarded by a query: `(rewrite/when (proof …) (lower-as …))`.
  `priv/std/rewrite.bl` exists as the rewrite engine; `priv/std/optics.bl`
  navigates the tree. These become `self.opt` rules (design doc §5) over
  bl-ANF / cerl.
- Order: 6 (free, no risk) → 3 (private fns only) → 5 (pure win, tiny) →
  4 → 1 (needs the state-shape join) → 2 (needs call-graph rewriting; last).
- Gate per rule: obligation + `bench/` case that shows the instruction the
  rule was meant to remove is gone (`erts_debug:df` disassembly diff, or
  `beam_disasm`), not just "faster".
