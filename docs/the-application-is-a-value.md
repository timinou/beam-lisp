# The application is a value

What FEAT-016 actually opened, and why it is bigger than a live board.

FEAT-016 is done. Its design — *broadcast the moment, never the projection* —
looks like a modest choice about a PubSub payload. It is not. It is the last
join in a set of five ideas that were each built separately in this repo and
turn out to be one idea:

| idea | what it contributes |
|---|---|
| **EDN / homoiconicity** | a program is a value you can hold |
| **datom** | a value you can hold can be *stored*, *ordered in time*, and *queried* |
| **GenServer** | the one moving part, serialised, named, supervised |
| **LiveView** | a process whose state a browser mirrors |
| **Spacetime** | a browser whose DOM is a projection of state, not a template |

Each is ordinary alone. Composed, they say something no one of them says:

> **The interface is a value. The database stores values. The basis orders
> them in time. ∴ the application's own definition is queryable history, and
> a page is a projection of (definition, data, who is asking) — all three of
> which are values, at a point in time you can name.**

Everything below is verified in-tree, and the two probes at the end are
runnable.

---

## 1. What FEAT-016 actually decided

The shipped rule, from `spell.server/topic`'s own docstring:

> What arrives on the topic is a BASIS, never a rendered board. At the
> instant of a write the only thing that is true is that the database
> advanced; which rows changed, and what any given page should now show, is
> derived by the READER from its own question.

Written as a type, this is the whole essay:

```
page   :   (definition, data, asker) → DOM
broadcast :  the moment the data moved         ← a number
```

A projection is a function of **three** arguments, and a writer knows only
one of them. Reel proves it concretely: `board-assigns` is `(db, role)`, and
`task-rows db role` computes each row's legal moves from
`reel.work/affordances`. The same task at the same instant offers
`[doing dropped]` to a tech lead and `[dropped]` to a product lead. Broadcast
a rendered board and one of those two people is looking at the other's
answer.

So the message shrinks to a number, and every subscriber recomputes *its own*
question. That is the move. And once you see the payload is a **basis**, you
notice the basis is not a notification — it is a **coordinate**.

---

## 2. The five ideas, and the join

### EDN: the definition is data

A contract is not a class, a module, or a macro expansion. It is a map, made
by `spell.contract/parse`, holding `:assigns :events :infos :opts`. Handler
bodies are **quoted forms** — `(quote (on :create [title] …))` — stored, not
compiled.

Two runtimes are projected from it: `machine-module` emits the Elixir
LiveView, `machine-page-edn` emits the Spacetime page. Neither is written by
hand; they cannot disagree.

### datom: values become storable, ordered, queryable

`:db.type/term` is the hinge, and its docstring says so:

> Every BEAM term inhabits `:db.type/term`. This is not a hole in the type
> system, it is the point of one: codec.bl gives a total order to every term
> the language has, so a tuple, a nested map, a set or a pid can be indexed
> and range-scanned exactly like a string.

A contract is a nested map of quoted forms. ∴ **a contract is a legal datom
value.** Not by special-casing — by the codec already ordering every term the
language has.

### GenServer: exactly one moving part

`datom.conn`'s writer is an Agent, and the comment is precise about why: it
owns *nothing*. Every durable thing is in the store, the basis is in a shared
atom, so the process exists purely to serialise. Reads never touch it —
`(db conn)` is O(1), captures a basis, and ten thousand readers proceed in
parallel.

`next-tx-id` is a store counter from `FIRST-TX`, allocated **inside** that
writer and **recovered from the store on reopen**. So the basis is totally
ordered across restarts, not merely within one VM. And `transact-in-writer`
advances it with `max`, not `reset!` — a high-water mark, because a slower
transaction with a lower id landing last would otherwise rewind it and hide
every datom above the rewound mark (BUG-022: twenty writes, all committed,
all durable, sixteen visible).

**Everything downstream rests on that monotonicity.** It is why a basis can
be a coordinate rather than just a ping.

### LiveView + Spacetime: state mirrored, DOM projected

The LiveView holds authoritative assigns; the page holds signals. Diffs
cross, never templates. `on-info` clauses compile to real `handle_info/2`
heads — so a BEAM message and a browser click are decoded by *the same
contract*, through *the same walk*.

### The join

```
   a write            → a basis         (a coordinate, not a notification)
   a basis + a db     → a value         (as-of, O(1), shares the store)
   a value + a query  → an answer       (datalog, in the reader's process)
   an answer + a role → a projection    (the asker's own question)
   a projection       → a DOM           (Spacetime, push-native)
```

Every arrow is a pure function of values. The only impure step is the first,
and it happens in exactly one process.

---

## 3. What this unlocks, in order of increasing wow

### (a) The board is already time-travellable — for free

`datom/as-of` is O(1) and copies nothing: a historical value shares the same
store and differs only in its basis. `reel.read`'s every function takes a db
**value**, never a connection.

∴ the read model *already works against the past*, and nothing exercises it.
A read that accepts `{:as-of t}` gives:

| mode | meaning |
|---|---|
| live | subscribed; `t := latest` |
| paused | pinned to a `t` |
| scrubbing | `t` from a slider |

Same reader, same contract body, same walk, **no second set of historical
queries**. Reel becomes an actual reel: scrub to Monday, watch the board play
forward. Two tabs pin different moments and compare. The moment is
*renderable* — "as of tx 1000432" — so "are we looking at the same thing?"
becomes answerable instead of assumed.

This exists *only* because the database is a value, and it costs one
parameter on top of work already shipped.

### (b) The definition can live in the database too

Here is the turn. A contract is a value; `:db.type/term` stores any value;
datom versions every value it stores.

**∴ store the contract in the database.**

Verified — this runs (`/tmp/term_probe.exs`, reproduced in §5):

```
assigns-then  ["n"]              ; pulled as-of t1
assigns-now   ["label" "n"]      ; pulled at head
versions      3
```

And the pulled-back term is still a working contract (`term_probe2`):

```
handled          "ok"
assign-after     42
reply            "bumped"
module-compiles  true
```

A contract round-tripped through redb still drives `spell.server/handle` and
still emits a compilable LiveView module.

What that means:

- **The UI has history.** `datom/changes` on `:ui/contract` answers *"what has
  this page been, and when did it become so?"* — with a transaction id, a
  timestamp, and `:tx/by` naming who changed it, because
  `reel.store/transact-as!` already annotates `:db/current-tx`.
- **Schema migration and UI migration are the same operation.** Both are
  transactions.
- **Rollback is `as-of`.** Not a deploy; a coordinate.

### (c) The whole system becomes ONE query

Data lives in datom. Definitions live in datom. So a datalog query can span
both:

> *Which pages read an attribute whose values changed in the last hour, and
> who was looking at them?*

That is one query over one store. In a conventional stack the data is in
Postgres, the UI is in a git repo, the sessions are in ETS, and the question
is a research project.

This is where `spell.machine/report`'s static checks — `orphan-bindings`,
`unrendered-assigns`, `undeclared-template-holes` — stop being a linter and
become *queries over live facts*.

### (d) `read!` closes the loop: dependence observed, not declared

`walk` already records `:intents` from `do!`, `:pushes` from `push!`, `:ask`
from `ask!`. `read!` alone evaluates without recording — correctly, because a
body must compute with the answer. But the two are not exclusive:

```clojure
(= hd "read!")
(let [op (walk (second form) env st)
      payload (walk (nth form 2 nil) env st)]
  (swap! st (fn [s] (assoc s :reads (conj (get s :reads []) {:op (name op) :payload payload}))))
  (perform-read (name op) payload))
```

Five lines. **Zero new walker authority** — recording is exactly as pure as
`:intents` already is; the walker still cannot name a performer, still writes
only into its own state atom.

Then `:topic :board` need not be written at all. The read name **is** the
topic, and it is already registered via `register-reader!`. A page that reads
something is subscribed to it *by construction* — which is precisely the
"one need, one implementation" argument `:topic`'s own docstring makes
against a second spelling of `:mount-event`.

And the dataflow graph becomes a value:

```
intent :create-task → read :board → assigns @tasks @films … → 3 sockets
```

Both registries already exist (`spell.server/readers`,
`Server.performers/0`). This adds the edges. Since `spell.run`'s four-rung
ladder judges **model-proposed** contracts, "what does this proposal read,
and what invalidates it" being *computable* is a safety rung — not a
visualisation.

It also subsumes FEAT-016's own leftover: `@components`/`@leads` computed and
rendered by nothing is *an assign nothing depends on* — a derived fact, not a
`check.exs` heuristic.

### (e) The Smalltalk image, as diffable data

`docs/spacetime-interface-as-value.typ` describes four levels of
serialisability and calls L4 "a Smalltalk image — but diff-able, merge-able,
versionable data instead of a binary blob." It is marked *vision,
unimplemented*.

Most of the substrate now exists:

| level | status |
|---|---|
| L1 snapshot — signal values | assigns are values; `seed-assigns` reseeds |
| L2 structure — skeleton | `machine-shell` emits it |
| L3 behaviour — logic as data | handler bodies **are** quoted forms, walked |
| L4 live process — continuation | ✗ the missing piece |

L3 is the hard one and it is *done*: `spell.server/walk` is an interpreter
over stored forms with a closed vocabulary. A page's behaviour already
travels as data.

What datom adds that the vision doc did not have: **the image is versioned,
queryable, and time-indexed.** Not a blob you snapshot — a history you can
ask questions of.

---

## 4. Why the closed vocabulary is what makes this safe

Every step above widens what data can do. The obvious fear: a contract from
the database is data from the world, and interpreting data from the world is
how systems get owned.

The walker is the answer, and it was built for exactly this. Its vocabulary
is closed — special forms plus a whitelist of pure functions — and an unknown
head is **refused by name**, never resolved. `server.bl` states the
alternative and rejects it: a fallback to `apply` would be *"an evaluator
wearing a costume"*.

Three properties compose:

1. **The walker cannot act.** `do!` *records*; the host performs. A body
   cannot name a performer, so it cannot discover what exists.
2. **The host bounds the vocabulary structurally.** `declared_only/3` refuses
   any assign a contract did not declare — because `assign_all` calls
   `String.to_atom/1`, and an unbounded `to_atom` over wire data fills the
   atom table and aborts the VM uncatchably. The bound is structural rather
   than a rule performers are asked to follow.
3. **The reader is bounded too.** An unregistered read fails by name.

∴ storing contracts in a database does not widen the attack surface, because
the interpreter never had ambient authority to begin with. *That* is why this
design can be pushed as far as it can.

---

## 5. Reproducing the proof

```elixir
# /tmp/term_probe.exs
BeamLisp.init()
BeamLisp.Env.add_search_path(Path.expand("spell/src"))
BeamLisp.Loader.ensure_loaded("datom")
BeamLisp.Loader.ensure_loaded("spell.app")
```

```clojure
(let [conn (datom/connect [{:db/ident :ui/name :db/valueType :db.type/keyword
                            :db/cardinality :db.cardinality/one
                            :db/unique :db.unique/identity}
                           {:db/ident :ui/contract :db/valueType :db.type/term
                            :db/cardinality :db.cardinality/one}])
      term (spell.contract/parse :probe-live {}
             (list (quote (assign @n :integer 0))
                   (quote (on :bump [] (do (set! @n (inc @n)) (ok "bumped"))))))
      r1 (datom/transact! conn [{:db/id -1 :ui/name :probe :ui/contract term}])
      t1 (datom/basis-t (get r1 :db-after))
      term2 (spell.contract/parse :probe-live {}
              (list (quote (assign @n :integer 0))
                    (quote (assign @label :string))
                    (quote (on :bump [] (do (set! @n (inc @n)) (ok "bumped"))))))
      _ (datom/transact! conn [{:db/id -1 :ui/name :probe :ui/contract term2}])
      back-then (datom/pull (datom/as-of (datom/db conn) t1) [:ui/contract] [:ui/name :probe])
      now       (datom/pull (datom/db conn) [:ui/contract] [:ui/name :probe])]
  {:assigns-then (vec (sort (map name (keys (get (get back-then :ui/contract) :assigns)))))
   :assigns-now  (vec (sort (map name (keys (get (get now :ui/contract) :assigns)))))})
```

```
%{"assigns-then" => ["n"], "assigns-now" => ["label", "n"], "versions" => 3}
```

And that the pulled term still works:

```clojure
(let [pulled (get (datom/pull (datom/db conn) [:ui/contract] [:ui/name :probe]) :ui/contract)
      result (spell.server/handle pulled :bump {} {"n" 41})]
  {:handled (get result :status)
   :assign-after (get (get result :assigns) "n")
   :module-compiles (string? (spell.contract/elixir-module pulled "Probe.Live" ""))})
```

```
%{"handled" => "ok", "assign-after" => 42, "module-compiles" => true}
```

---

## 6. The ladder from here

Each rung is independently valuable and independently verifiable. None
requires the next.

| # | rung | cost | unlocks |
|---|---|---|---|
| 1 | `read!` records into `:reads` | ~5 pure lines | dependence observed; testable with no socket/store/browser |
| 2 | derive `:topic` from recorded reads | small | the contract clause disappears; one need, one impl |
| 3 | per-socket `t_seen` watermark | small | reconnect-catchup and live-push become one path |
| 4 | reads accept `{:as-of t}` | one param | pause, scrub, compare — **the demo** |
| 5 | contracts stored as `:db.type/term` | medium | UI history, `:tx/by` authorship, rollback = `as-of` |
| 6 | datalog across data + definitions | falls out of 5 | "which pages read what changed?" as one query |
| 7 | L4 continuations | large | the diffable image |

Rung 3 fixes a real remaining gap: as shipped, `on-info` re-reads
unconditionally and the basis is bound but unused, so a page that missed a
broadcast while backgrounded stays stale until something else wakes it — the
same class of gap FEAT-016 fixed, at a different cause.
`reel.read/changed-since` already computes the delta.

---

## The through-line

Clojure's claim is that a program is data. Datomic's is that a database is a
value. LiveView's is that a page is a process. Spacetime's is that a DOM is a
projection.

Each was built by different people for different reasons, and on the BEAM
they turn out to be the same claim wearing four hats. This repo is where they
meet — and FEAT-016's small decision, *broadcast the moment and let each
reader ask its own question*, is the one that makes the meeting load-bearing
instead of merely elegant.

A basis is not a notification. It is a coordinate in the history of a value
— and once the definition of the application is stored beside its data, that
history includes the application itself.

---

## See also

- `!tasks/features/FEAT-016-*` — the feature, its evidence, and the
  re-derivation appended to it
- `docs/spacetime-interface-as-value.typ` — the four serialisability levels
- `docs/spacetime-lisp-machine.typ` — owners as processes, the evolution loop
- `docs/building-an-app.md` — the practical guide to building on this
- `priv/datom/schema.bl` — `:db.type/term`, and why it is declared
- `priv/datom/conn.bl` — the single writer, and why the basis is a high-water
  mark
- `spell/src/spell/server.bl` — the closed vocabulary, and `topic`'s rationale
