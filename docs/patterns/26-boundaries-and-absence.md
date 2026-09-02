# 26 — Boundaries, absence, and strictness

*Three semantic gaps that patterns close: what happens to untrusted data at
the edge, the difference between "absent" and "nil", and how strictness
becomes something the proof reports rather than something the author
risks.*

## 1. The boundary pattern

Data arriving from outside — HTTP JSON, a NIF, another node, a file — is
a binary or a map of binaries. Two things must happen before it is a bl
value: its shape must be checked, and some of its keys must become
keywords. The second is dangerous: **atoms are never collected**, and a
full atom table aborts the VM. `BeamLisp.AtomGuard` samples the table and
refuses past a high-water mark — "an alarm, not a quota", as its own doc
says. It cannot know *which* atoms a program meant to create.

A pattern at the boundary knows exactly which:

```clojure
(defn handle-request [(?json {:keys [user action] :strs [payload]})] …)
```

The view `?json` decodes to a string-keyed map. The pattern names two keys
to become keywords — `user`, `action` — and one to stay a string. The
lowering: `#{<<"user">> := User, <<"action">> := Action, <<"payload">> :=
Payload}` — a binary-keyed map match. **No atom is created from input.**
The keyword names in the source are the only atoms, and they exist at
compile time. `String.to_atom` never runs.

That turns `AtomGuard` from a runtime alarm into a **static guarantee** for
every boundary written as a pattern: the atom set a program can intern
from input is the set of keyword literals in its boundary patterns —
finite, known at compile time, a `codebase` query. `AtomGuard` stays for
the paths that bypass patterns (REPL, generated source), which is what it
was for.

The same pattern is the *contract* (capsule 20's `matches?`): a request
that fails the boundary pattern gets `explain`'s structured mismatch as
the 400 body, generated, path-precise. And it is the *coercer*: `?view`s
in the pattern (`(?parse int)`, `(?re …)`) convert at the edge, once, so
the interior never sees a string that should be a number.

`docs/trust-boundary.md` says compiler input is trusted and runtime input
is not; boundary patterns are where that line is drawn in code.

## 2. Absence ≠ nil

Clojure's `{:keys [a]}` binds `a = nil` both when `:a` is absent and when
`:a → nil`. `RT.get` does the same. Core Erlang distinguishes them —
`is_map_key/2` vs `map_get/2` — and so does every database, every JSON
codec, and every "was this field sent" question. bl conflates them at
the pattern layer; users write `(contains? m :a)` around the pattern to
recover the distinction.

Two additions to the pattern vocabulary, both lowering to guard-safe
tests (capsule 11):

```clojure
{:keys [a] :absent [b]}        ; matches only if :b is NOT a key
{:keys [a] :present [c]}       ; :c must be a key (its value may be nil)
(?nil x)                       ; x is bound and is nil (key present)
```

and a tightening of `:or`: `{:or {b 0}}` today means "absent → 0"; it
should also be *explicit* that "present with nil" keeps nil (Clojure's
rule). The normal form carries `:default` for absent and nothing for
present-nil — so the obligation (capsule 03) verifies the lowering
preserves exactly Clojure's rule, and `explain` can say "key `:b` is
present but nil" versus "key `:b` is absent".

Where it pays: datom entity maps (attribute absent vs asserted-nil are
different facts — `pull` today has to encode this), `code_change` (an old
state missing a field vs having it nil), and every boundary (a JSON
`null` vs a missing key).

## 3. Strictness as a proof report

`^:strict` on a pattern (or a namespace-level default) makes it rigid:
`[a b]` requires exactly two elements, `{:keys [a]}` requires `:a`
present. Mismatch → `match_fail` with `explain`. Opt-in only; the lenient
default is untouched — capsule 03 guarantees the lowering never tightens
on its own.

But the obligation machinery yields something better than an opt-in
flag. For every lenient pattern, the abstract-domain evaluation (capsule
03) knows whether the lenient cases are **reachable**:

```
(defn area [[w h]] (* w h))
;; lenient: h may be nil → (* w nil) throws ArithmeticError
;; typed: every caller passes a 2-vector literal
;; ⇒ the len-1 case is unreachable ⇒ the pattern is EFFECTIVELY strict
```

`codebase` records `(effectively-strict ?pat ?evidence)`. The compiler
emits the rigid clause *without* the fallthrough (capsule 13 §3) — the
same code `^:strict` would produce — and the fact is visible: hover shows
"strict in practice: all 4 callers pass 2-vectors". Adding `^:strict` then
changes nothing but documents intent. The lenient patterns that are *not*
effectively strict are the interesting list: each is a place where a
`nil` can enter silently, i.e. exactly the bugs Clojure's leniency hides.

So strictness has three states, all reported, never silent:

| state | who decides | code |
|---|---|---|
| lenient, reachable | default | rigid clauses + step fallthrough |
| lenient, unreachable ("effectively strict") | the proof | rigid clauses, no fallthrough, fact recorded |
| `^:strict` | the author | rigid clauses, `match_fail` + `explain` on miss |

## Sketch

- `pattern.bl`: `?json`/`?parse`/`?re` views; `:absent`/`:present`/`?nil`
  constraints; `^:strict` → `(:len (:= n))` and `(:has …)` in the normal
  form.
- Boundary lowering: string-keyed map patterns emit binary-key matches;
  `codebase` fact `(boundary-atoms ?ns ?set)`.
- `pattern-ob` records reachability of lenient cases; `codebase`
  `(effectively-strict …)`.
- `web.bl` / `live.bl` request handlers accept boundary patterns and
  return `explain` as the error body.
- Gate: `test/bl/boundary_test.bl` — a JSON handler with a deliberate
  unknown key proves no atom is created (`:erlang.system_info(:atom_count)`
  before/after, exact); absence vs nil round-trips through `datom.pull`.
