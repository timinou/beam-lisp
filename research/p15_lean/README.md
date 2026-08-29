# P15 — the Lean tier: findings (c, d, e, f; a and b shipped earlier)

Run:
```
elixir $(for d in _build/test/lib/*/ebin; do echo -pa $d; done) \
  -e 'BeamLisp.init()
      BeamLisp.Env.push_load_path("priv")
      BeamLisp.Env.push_load_path("research/p15_lean")
      BeamLisp.run_file("research/p15_lean/run.bl")'
```

((a) evidence table + hover shipped in P2/typed; (b) hole synthesis
shipped as MVP-D's demo.)

## (c) effect lattice — PASS

`pure < atom < process < io`, `:unknown` top. A 3-fn chain
run-it→step→bump→swap! infers :atom at every level; a `^:pure` claim on
run-it is REJECTED, naming the effect and the line; a genuinely pure fn
claiming `^:pure` is silent. Unknown callees are :unknown — you cannot
claim pure over code you cannot see (sound). This is MVP-F's substrate.

## (d) termination — PASS

`(loop [i n] … (recur (dec i)))` accepted; `(recur (inc i))` rejected
with the failing form; `(recur (rest ys))` accepted;
`loop ^{:decreasing (count xs)}` trusted-and-reported (L13 escape
hatch is AUDITABLE, not silent). **Division of labor discovered**: the
termination checker owns SHAPE (structurally shrinking), the type
checker owns TYPE (a `dec` on a string crashes — that is P1's warning,
not a divergence). Nested loop/fn boundaries: each recur answers to its
own loop.

## (e) deferred constraints — PASS (L7 mechanism, first real client)

File A calls `(helper "s")` before helper exists: 0 warnings, 2
deferred constraints. When p15run's `^{:args [int]}` helper loads, the
constraint retries and the string argument is now provably wrong: 1
warning. `never-defined` stays deferred forever → listed in the DAG-end
report as silent-unknown. Unknown is never a wrong warning AND never
forgotten.

## (f) ^:opaque — PASS (L9 reducibility knob)

`(def ^{:ret int} lying-transparent "not an int")` → warning (declared
int, body string). `(def ^:opaque ^{:args [int] :ret int} trusted …
"lies too")` → trusted at its declared sig, body never walked. Trust is
auditable: the sig table records `{:opaque true …}`. Meta plumbing
note: stacked `^` wraps nest ({:meta {:meta sym m1} m2}) and reader
position maps carry :line — `name-meta` merges annotation layers and
skips position maps (both bugs bit; both fixed at the rule level).

## Known sharp edge (owned by P11)

Termination rejections print the raw reader tuple, not the delaborated
form. P11's error-rendering pass fixes this across all warnings (L12).
