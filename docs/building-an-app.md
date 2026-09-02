# Building an app on beam-lisp: datom + spell, layer by layer

How to stand up a new application of the same shape as `projects/reel` — a
durable graph, a read model, a page whose two halves are emitted from one
term, and a verification ladder that catches the defects before a browser
does.

Everything below is drawn from the working system. Where a rule exists
because something broke, that is said, because a rule whose reason is lost
gets deleted by the next person.

---

## 0. The shape, in one picture

```
    browser                        BEAM
    ───────                        ────

    Spacetime page   ◀── emitted ──┐
    (signals, DOM)                 │
        │  fire :create "title"    │
        ▼                          │
    LiveView socket                │   ONE contract term
        │                          │   (data, in beam-lisp)
        ▼                          │
    generated module ──────────────┘
    (machine-module)
        │  delegates, never decides
        ▼
    spell.server/handle      ← closed-vocabulary walk of the handler body
        │  records {:intents :reads :pushes :ask}, performs nothing
        ▼
    BeamLisp.Spell.Server    ← the authority: looks up a performer, calls it
        │
        ▼
    <app>.intent/perform     ← YOUR beam-lisp: validate, write, read back
        │
        ▼
    <app>.store  ──▶ datom ──▶ redb
```

Two properties hold this together, and both are worth stating before any
code:

1. **The page and the server half are two projections of one term.** They
   cannot disagree about events, assigns, pushes, or reply tags, because
   nobody writes them twice.
2. **The handler body is data, walked by a closed interpreter.** It can
   compute; it cannot act. It says what it *wants* (`do!`, `read!`, `ask!`)
   and a layer with the authority does it. That is what lets a contract be
   proposed by a model without handing it the runtime.

---

## 1. The layers, and the rule that orders them

Copy `reel/app.bl` — the manifest namespace. Loading it loads the
application, because the loader computes order from the `(:require …)`
forms.

```clojure
(ns myapp.app
  (:require [myapp.schema]     ; what the system can say         (no deps)
            [myapp.store]      ; the durable connection, a process (schema)
            [myapp.work]       ; the lifecycle: states, legal moves (schema)
            [myapp.read]       ; the datalog queries — the read model (schema)
            [myapp.intent]     ; an intent becomes a transaction  (store work read)
            [myapp.corpus]     ; seed data, as terms              (read store)
            [myapp.ui.board])) ; contracts and views              (read)
```

**The rule: nothing reaches down past its layer; nothing below knows a layer
above exists.**

The sharpest instance: **`read` knows nothing of `store`.** Every query takes
a database *value*, never a connection and never the process. That single
choice buys three things:

- a whole page renders from ONE value and is therefore *consistent* — not
  six queries at six moments that can disagree about whether a task exists;
- every query is testable against an in-memory store with no process running
  and no file on disk;
- `as-of` is free. A historical value **is** a database value, so the same
  functions answer about the past. There is no second set of "historical"
  queries to keep in step.

Do not put the manifest in Elixir, and do not glob `src/**/*.bl`. A glob
loads whatever happens to be on disk (a scratch file included) and decides
order by filename.

---

## 2. Schema — the design document, as data

`myapp/schema.bl`. This file, read top to bottom, **is** the domain. An
attribute is a fact the system can hold, and the set of attributes is what
the system can say; nothing elsewhere may say anything it does not permit.

```clojure
(def identity-attrs
  [{:db/ident :myapp/slug
    :db/valueType :db.type/string
    :db/cardinality :db.cardinality/one
    :db/unique :db.unique/identity
    :db/doc "A stable, human-readable name. Upserts: loading twice updates."}

   {:db/ident :myapp/kind
    :db/valueType :db.type/keyword
    :db/cardinality :db.cardinality/one
    :db/index true
    :db/doc "What this entity IS. A tag rather than a table."}])
```

Reading an attribute:

| key | meaning |
|---|---|
| `:db/ident` | the keyword it is known by (required) |
| `:db/valueType` | `string long boolean keyword ref instant term` |
| `:db/cardinality` | `one` (default) \| `many` |
| `:db/unique` | `identity` (upserts) \| `value` (refuses a duplicate) |
| `:db/index` | maintain AVET, so a range scan can push down |
| `:db/doc` | what it means |

### Three decisions worth making deliberately

**`:db.unique/identity` on your slug.** This is what makes a seed corpus
idempotent: a tempid asserting a unique-identity value *upserts* onto
whatever entity already holds it. So `corpus/load!` runs on every boot with
no "have I already seeded?" flag anywhere to fall out of step with the
database. `:db.unique/value` would make the second load an **error** — right
for an invoice number, wrong for a definition that evolves.

**A `:kind` tag, indexed, instead of tables.** "All films" is then one
clause — `[?e :myapp/kind :film]` — with no join, and because it is indexed
it is an AVET range rather than a scan of the world.

**`:db.cardinality/many` is the sharpest key here.** It decides whether
asserting a value *replaces* the old one or accumulates beside it. Getting
it wrong is silent: a many-attribute recovered as one collapses its values
to whichever the scan reached last.

Schema is a value: `(transact! conn schema)` installs it, `(pr-str schema)`
prints it, a test asserts on it, and a migration is an ordinary transaction.

---

## 3. The pure domain — put rules in a map, not in control flow

`myapp/work.bl`. The usual shape is a `case` in a handler: read the state,
write the new one, hope every call site agrees which pairs are legal. The
rules then live in control flow, where they cannot be enumerated, tested, or
shown to a user — so the UI grows its own copy and the two drift.

Make them data:

```clojure
(def transitions
  {:todo    [:doing :dropped]
   :doing   [:review :todo :dropped]
   :review  [:done :doing]
   :done    []          ; terminal — EXPLICIT, so it reads as decided
   :dropped []})        ; rather than forgotten

(def permissions
  {:tech    #{:doing :review :todo :done :dropped}
   :product #{:todo :review :done :dropped}
   :sales   #{:dropped}})
```

Two maps, deliberately not folded into one. **Legality and permission are
different questions and a UI needs them apart**: an illegal move should not
be offered at all, while a legal move that is not yours should be visible
and refused. Collapse them and a person cannot tell "that cannot happen"
from "you cannot do that", and files a bug about the wrong one.

The board's affordances and the write's validation then come from the same
map — *an offered action is a legal action by construction*, with no second
list to maintain.

---

## 4. Read model — one function per question

`myapp/read.bl`. Every function takes a db **value**. Datalog answers a
*set* of tuples (the same answer arriving by two derivations is one answer),
so ordering is the caller's business: sort here, once, rather than leaving a
page to render whatever order a set iterates.

```clojure
(defn unrealised-components
  "Components with no task building them, and their state."
  [db]
  (vec (sort-by
         (fn [r] (str (get r 0)))
         (to-list
           (datom/q (quote [:find ?slug ?state
                            :where [?c :myapp/kind :component]
                                   [?c :myapp/slug ?slug]
                                   [?c :component/state ?state]
                                   [:not-join [?c] [?t :task/realises ?c]]])
                    db)))))
```

`:not-join` is what makes it *one query*. The alternative — pull every task
and every component and subtract in the host — is the same answer computed
somewhere it cannot be indexed.

### The projection boundary is not optional

A page cannot walk a namespaced key. `@f.film/status` reads as a *namespaced
symbol* (namespace `f.film`, name `status`), so the template checker reports
an undeclared hole called `status` in a template whose parameter is `$f`.
**A `/` cannot appear in a path a template walks.**

So project, with the two vocabularies visibly separate:

```clojure
(defn- row [entity pairs]
  (reduce (fn [m pair]
            (let [v (get entity (first pair))]
              (assoc m (second pair) (if (nil? v) "" v))))
          {} pairs))

(row f [[:myapp/title :title] [:film/status :status] [:myapp/slug :slug]])
```

Projecting is better anyway: a view saying `@f.title` knows a film has a
title; one saying `@f.myapp/title` knows how *this database spells it*, and
would have to change if the schema renamed an attribute the page never cared
about.

### Two rules learned expensively

**Absence is not a state.** A pattern only matches where its attribute
exists, so an entity with no `:component/state` binds *nothing* and silently
backs every requirement that needs it. Query the absent case separately
(`[:not-join [?c] [?c :component/state _]]`) and treat absent as the unsafe
value. Cost of being wrong that way: something held back until a human
looks. Cost the other way: a demo that fails in front of a customer.

**An empty list is an answer, not an absence.** "Every requirement is
asserted" is the best result the tool can report and renders identically to
a query that crashed. Compose the sentence server-side — a template walks
values and cannot ask how many there are:

```clojure
(defn verdict [coll noun empty-says]
  (let [n (count coll)]
    (cond (= n 0) empty-says
          (= n 1) (str "1 " noun)
          :else   (str n " " noun "s"))))
```

`empty-says` belongs to the caller, because only the caller knows what
nothing *means*: no unproven requirements is good, no showable films is bad.

### A produced stream must be built lazily, or it is not a stream

When a read model *produces* a value that its caller consumes incrementally —
Server-Sent Events to a browser, a chunked HTTP body, anything written to a
socket as it is realized — **how** the sequence is built decides whether it
streams at all, and the two ways look identical at the call site.

`Enum/*` is **eager**: `(Enum/map coll f)` walks all of `coll` and returns a
finished list. `Stream/*` is **lazy**: `(Stream/map coll f)` returns a
description that produces each element only when the consumer pulls it. So a
function that maps provider chunks into SSE frames with `Enum/flat_map`
**buffers the entire upstream response** before the consumer sees byte one —
the request "streams" to no one, and a slow or endless upstream hangs the whole
response. Switch the same code to `Stream/flat_map` + `Stream/concat` and each
frame reaches the socket the moment the provider emits it.

```clojure
; EAGER — realizes every chunk before the caller gets the first frame
(defn frames [chunks]
  (Enum/flat_map chunks (fn [c] [(encode c)])))

; LAZY — one frame produced per chunk pulled; TRUE streaming
(defn frames [chunks]
  (Stream/flat_map chunks (fn [c] [(encode c)])))
```

The trap is that laziness is **invisible in a test**: both versions pass
`(is (= expected (Enum/to_list (frames input))))`, because the assertion
realizes the whole sequence anyway. The difference shows only under a real
consumer, as latency-to-first-byte or a hang. Diagnose it deliberately — put a
side effect in the mapping fn and count how many times it ran before you pull
the second element:

```clojure
(let [n (atom 0)
      s (Stream/map (range) (fn [x] (swap! n inc) x))]
  (Enum/to_list (Stream/take s 2))
  (deref n))            ; lazy → 2, eager → would never terminate on (range)
```

The rule: **a value the caller consumes lazily MUST be built with `Stream/*`;
`Enum/*` realizes eagerly.** beam-lisp's own `lazy-seq` (and the hybrid
`map`/`filter`/`take` over a `LazySeq`, section notes in `core.bl`) compose
lazily too — but the moment the sequence crosses into an Elixir library that
speaks `Stream`, it is `Stream/*` that keeps the laziness the boundary needs.

---

## 5. Store — the one mutable thing, as a supervised process

`myapp/store.bl`. Everything else is a value; something has to hold the
moving end, and on the BEAM the honest place for a moving end is a process
with a name under a supervisor.

```clojure
(defserver store
  (init [path]
    (ok {:conn (datom/connect-with (datom.store-redb/open path) myapp.schema/all)
         :path path}))

  (handle-call :db   [_from state] (reply (datom/db (get state :conn)) state))
  (handle-call :conn [_from state] (reply (get state :conn) state))

  (terminate [_reason state]
    (datom/release! (get state :conn))
    :ok)

  (handle-info _msg [state] (noreply state)))
```

**It is not a repository and holds no queries.** Callers ask for `(db)` — a
value, O(1), it captures a basis rather than data — and query it themselves.
∴ reads never touch this process, so it cannot be a bottleneck and a slow
query cannot block a write. The alternative (a GenServer with `get_tasks`,
`get_films`, …) grows one call per question, serialises every read through
one mailbox, and re-implements the query language it sits on.

Four things that will bite:

- **`terminate` must `datom/release!`.** `datom.conn` keeps a process-wide
  registry mapping each store to its writer and basis. That is a live
  reference, and redb's file handle is a Rustler resource freed by GC — so
  an unreleased entry keeps the **database file locked** for the life of the
  VM. A store whose process is provably dead still owns its file, and
  reopening fails with a lock error naming it.
- **`terminate` does not run on a brutal kill.** Nothing does. Hence
  `release!` is idempotent, and a caller reopening after a crash may still
  wait for collection.
- **`erlang/whereis` answers the atom `:undefined`,** not nil, for an
  unregistered name. `(not (nil? …))` therefore returns *true* for a name
  nothing holds — a health check that cannot report ill health.
- **The name is what makes state identity independent of code identity.**
  The process keeps its connection across a reload of the namespace, because
  the name is what is looked up.

Give writes one door, and annotate them:

```clojure
(defn transact-as! [tx-data note lead]
  (let [annotation (if (nil? lead)
                     {:db/id :db/current-tx :tx/note note}
                     {:db/id :db/current-tx :tx/note note :tx/by lead})]
    (transact! (conj (vec tx-data) annotation))))
```

The annotation rides `:db/current-tx` — the transaction *is* an entity, so
describing it costs one datom and makes the change self-describing.
**This is why there is no activity table:** an events table written alongside
a change can disagree with the change; a fact recorded *on* the change
cannot.

---

## 6. Intent — a pure half and a dull impure half

`myapp/intent.bl`. This is the layer FEAT-016 is really about, so build it
with the split intact.

### `tx-for` — pure: intent + db → transaction data, or a refusal

```clojure
(defn tx-for [db op payload]
  (let [get* (fn [k] (get payload (name k)))]
    (cond
      (= op :refresh) {:tx [] :note ""}

      (= op :create-task)
      (let [title (get* :title)]
        (if (blank? (str title))
          {:refused "A task needs a title — it is what everyone else will read."}
          {:tx [{:db/id -1 :myapp/slug (slug-for title) …}]
           :note (str "created task \"" title "\"")}))

      :else
      {:refused (str "\"" (name op) "\" is not something this application does. "
                     "It answers to: " (join ", " (map name ops)) ".")})))
```

Every rule lives here, and it needs no substrate to check — no store, no
socket, no process.

**A refusal is a value, not an exception**, because a refused intent is an
ordinary outcome (someone typed an empty title) and the page must render the
reason. Exceptions are for the impossible.

**A refusal is a sentence and it goes to a person.** Two rules: say what is
wrong, not that something is; say what would be right, when that is knowable.

### `perform` — impure: validate, write, read back

```clojure
(defn perform [op payload]
  (let [op-kw (keyword (str op))
        db (myapp.store/db)
        result (tx-for db op-kw payload)]
    (if (contains? result :refused)
      (merge (board-assigns db) {"notice" (get result :refused)})
      (let [outcome (if (empty? (get result :tx))
                      (get result :note)
                      (try (do (myapp.store/transact-as! (get result :tx)
                                                         (get result :note) nil)
                               (get result :note))
                           (catch e (if (cas-failure? e)
                                      (stale-notice payload)
                                      (throw e)))))]
        (merge (board-assigns (myapp.store/db)) {"notice" outcome})))))
```

Five things in that shape are load-bearing:

- **A fresh `(store/db)` after the write.** A database value is immutable, so
  the one above answers forever with the world *before* this transaction —
  exactly the property that makes it safe to hold, and exactly the trap if
  you hold it too long.
- **An empty transaction is skipped.** A write with no datoms appends a
  moment in which nothing happened, and "what changed since Monday?" would
  have to learn to ignore them.
- **The catch is NARROW.** A bare `catch` turns a schema violation, a full
  disk and a NIF crash alike into "somebody else changed this — refresh and
  try again": not a degraded message but a **false** one. It sends a person
  to reload a page over a database that is failing, and hides the failure
  from whoever could fix it. Discriminate structurally —

  ```clojure
  (defn- cas-failure? [e]
    (let [data (ex-data e)]
      (and (map? data) (contains? data :expected) (contains? data :actual))))
  ```

  `:expected` appears in no other error this path can produce, which is
  better than matching a message string a reword would silently break.
- **A refusal answers with the board too.** The user's state has not changed
  and the page must say why.
- **String keys.** That is what crosses the seam; the contract's declared
  names are strings there.

### One reader, not seven

```clojure
(defn register-reads! []
  (spell.server/register-reader!
    :board
    (fn [params]
      (let [raw (or (get params :role) (get params "role"))
            role (if (or (nil? raw) (= (str raw) "")) nil (keyword (str raw)))]
        (board-assigns (myapp.store/db) role)))))
```

A reader *per assign* is a torn snapshot: each would call `(store/db)`
itself, so a mount running seven of them gives a page whose lists came from
different moments. One reader answering the whole page from one value is the
fix, and it is the *same function* an action's reply uses — so a page's
opening state and its state after a click are one moment each, computed by
one function.

**Read both spellings of a param key.** A handler body writes
`(read! :board {:role role})`, so the key arrives as the keyword `:role`; a
caller passing a wire map sends the string. Reading only one answers nil
silently.

---

## 7. The contract — one term, two runtimes

`myapp/ui/board.bl`. `@name` marks a binding that **crosses the seam**: on
the BEAM it reads `socket.assigns.name`, in Spacetime it is the `$name`
signal. A binding *not* declared here is page-local — that is the definition
of "shared", not a separate annotation.

```clojure
(def contract-term
  (parse :board-live
         {:bundle (Elixir.BeamLisp.Spell.Build/bundle_url)
          :root ".myapp"
          :mount-event :refresh}
         (list
           (quote (assign @tasks :list))
           (quote (assign @notice :string))
           (quote (assign @board :map))

           (quote (on :refresh [role]
                    (do (set! @board (read! :board {:role role}))
                        (set! @tasks (get @board "tasks"))
                        (set! @notice "")
                        (ok "refreshed"))))

           (quote (on :create [title]
                    (if (blank? title)
                      (err "A task needs a title.")
                      (do (do! :create-task {:title title})
                          (ok "created"))))))))
```

### The vocabulary a handler body may use

Special forms: `if do and or quote set! push! ask! do! read! ok err
live-vars`. Plus a whitelist of pure functions (`append str count get get-in
nth name keyword empty? blank? not nil? string? first last rest reverse conj
assoc merge take drop inc dec + - = not= < >`).

An unknown head is **refused by name**, never resolved. A walker that fell
back to `apply` would be "an evaluator wearing a costume" — and a contract
can be proposed by a model, at which point the four-rung safety ladder would
be checking the page while the server half was unguarded.

The cost is honest: when a contract needs more, the list grows deliberately,
one reviewable line per capability.

### `do!` vs `read!` — the asymmetry is the whole design

| | records | performed | may run at mount |
|---|---|---|---|
| `(do! :op payload)` | into `:intents` | after the walk, by the host | **no** |
| `(read! :op payload)` | evaluates inline to the answer | wherever it appears | **yes** |

`do!` is `ask!` with the operation named rather than assumed. The walker's
authority is unchanged: it writes into its own state atom, calls nothing it
was not handed, and cannot even *name* a performer — the registry lives in
the host, so a body saying `(do! :whatever …)` has no way to discover whether
anything answers. An unregistered op fails in the host, by name, which is
where the authority to perform lives.

`read!` evaluates rather than records because a body reads *in order to
compute*: `(set! @tasks (read! :tasks {}))` is the shape every such handler
wants, and a recorded read would force the host to merge results the body
could not see.

### The mount trap — it will cost you a boot

**Phoenix mounts a LiveView twice per live navigation** (disconnected static
render, then connected socket). An event handler runs once per click; a mount
event runs once per *render pass*. So a `do!` in a mount event is a write per
page load, performed twice, half of it in a request process that exits
immediately afterwards — taking any async reply with it.

The host **refuses it, loudly**. A contract whose mount event says `do!` is
expressing an intention that path cannot honour, and silence would make it
look like it had.

∴ `:mount-event` handlers **read**. Every mount of the reel board raised
before rendering until this was understood.

### Two more, both observed

**One read, not seven, in the handler too.** The walker has no `let`, so a
value that must survive from being read to being destructured has to be an
*assign*. Hence `@board` — declared, holding the whole answer, with the
rendered assigns as projections of it. Costs a little redundancy on the
wire; buys the property the page needs.

**A page-local crosses the seam by being PASSED, not read.** A handler body's
env binds the handler's own params and nothing else. `@role` inside a body
resolves a name the server cannot see. Declare the parameter — `(on :refresh
[role] …)` — and have the page fire it.

---

## 8. The view — three planes

`(parse-view :myapp-view (list (quote (markup …)) (quote (style …)) (quote
(binds …))))`. An unknown plane fails rather than being ignored: a silently
dropped plane is a page missing its styles.

### markup

```clojure
(template &shell []
  [:main {:class "myapp"}
   [:section {:class "panel"}
    [:div {:class "tasks"}]]])          ; empty: a bind fills it

(template &task [$t]
  [:article {:class "task" :data-state @t.state :data-slug @t.slug}
   [:h3 {:class "task__title"} @t.title]
   [:div {:class "task__moves"}
    [:button {:class "move move--1" :type "button"} @t.move1]]])
```

- **`&shell` holds NO holes.** It is rendered server-side once as static HTML
  and never invoked as a template, so a `@x` written into it emits a hole
  nothing binds and the browser paints the literal text. Observed: three
  panels captioned `` `$unrealisedSays` ``. A subscribed value reaches the
  DOM by being *mounted* — see `st/view` below.
- **A bind attaches to rendered DOM**, so the container must exist and be
  empty in the shell. An element no template renders cannot be bound.
- **`data-slug` is what makes write controls possible.** A control must name
  the entity it acts on, and the row is the only place that name exists in
  the DOM. With `data-key`/`data-index` only — positions in a list that
  re-sorts on every write — move buttons are not *missing*, they are
  *unwireable*.
- **A template body is an element, text, or a hole, and nothing else.** A
  nested `(st/each …)` inside one throws "not markup". A row that renders its
  own list must ask the read model for **fixed positional slots**
  (`:move1 :move2 :move3`), filled from the same affordance map that
  validates the write. `(get v i default)` does **not** answer the default
  past the end of a beam-lisp vector — it answers nil, which reaches the
  browser as the text `"nil"` — so bound-check in the projection.
- **A boolean hole renders as the empty string in attribute position**, so it
  carries no information while looking like it does. Say it in words.
- **Render the row's field, not the row.** `@r` where `@r.slug` was meant
  reaches the browser as `[object Object]`, once per row.

### style

```clojure
[".notice" {:margin "0.5rem 0 0" :color "#e8eaf2"}]
[".notice:not(:empty)" {:padding "0.5rem 0.75rem" :border-radius "0.5rem"}]
[".composer__input" {:value (inject @draft)}]
```

- **`(inject @x)` selects the `<-` reactive arrow; a bare `@x` is the `:` CSS
  surface.** Carried as different data deliberately — collapsing them
  reroutes a binding between `style.setProperty` and `setAttribute`
  (verse BUG-091). A bare binding emits `value: (deref draft);`, which verse
  refuses.
- **An input's value must follow its signal.** Otherwise clearing `@draft`
  after an add empties the *signal* while the `<input>` keeps its text, and
  the next keystroke writes the still-visible text back: task two arrives
  named `"firstsecond"`.
- **`:empty` will not collapse an interpolated element.** It renders an empty
  *string*, so it is not childless. Use `:not(:empty)` on the decoration.
- **A background needs a colour beside it** or the machine warns — correctly:
  an unreadable control is not a control.

### binds

```clojure
(binds
  [".tasks"  (st/each @tasks :as @t :template &task)]
  [".notice" (st/view @notice ["_" &notice])]
  [".move--1" (st/on :click (fire :move @t.slug @t.move1 @role))]
  [".role"   (st/on :input [(st/value @role) (fire :refresh @role)])])
```

- **Without an `@each`, the page receives every assign diff and discards it.**
  Subscription declared, template styled, nothing instantiating it — a defect
  this codebase has recorded twice.
- **`st/view` mounts a scalar.** One `_` arm when the page has no cases to
  distinguish.
- **Loop variables are in scope inside the `@each` that binds them** — which
  is what lets one selector serve every row without inventing an id per
  entity.
- **Two actions on one input**: write the signal, then re-ask the server. The
  board is re-read rather than re-filtered because the *rules* live on the
  server; a browser that recomputed which moves are legal would be the second
  copy the lifecycle-as-data design exists to prevent.
- **A `<select>`'s first option must be the empty state, visibly.** Every
  page-local is emitted as `""`, and a select is only written by `st/on
  :input` — so until somebody *changes* it, the signal is empty while the
  control displays whatever sits first. A select whose first option was
  "tech" showed tech, fired `""`, and the first move of every session was
  refused for a role the user could plainly see selected.

---

## 9. Boot — registration, and nothing else

`lib/myapp/boot.ex`. A **supervised child**, not a function called from
`Application.start/2`, because it *owns* the store: `server-start-link`
links, so whichever process calls it must be the one supervision restarts.
Calling it from `start/2` links the database to the application controller.

```elixir
def init(opts) do
  Myapp.init!()                                   # BeamLisp + spell.app + myapp.app
  store = Myapp.bl("myapp.store", "start!", [path])
  true = is_pid(store)                            # NB: a bare pid, not {:ok, pid}

  load_corpus()
  register_performers()
  Myapp.bl("myapp.intent", "register-reads!", [])

  machine = build_machine()
  BeamLisp.Spell.Server.register("board-live", "myapp.ui.board/contract-term")
  publish(machine)                                # emit EDN → spacetime serve
  generate(machine)                               # emit + compile the server half
  {:ok, %{path: path, machine: machine}}
end
```

The machine, and the two emissions:

```elixir
machine =
  Myapp.bl("spell.live", "seeded", [
    Myapp.bl("spell.machine", "empty-machine", []),
    BeamLisp.Vector.new([BeamLisp.Vector.new([
      BeamLisp.Env.fetch!("myapp.ui.board", "contract-term"),
      BeamLisp.Env.fetch!("myapp.ui.board", "view-term")])])])

# browser half
edn = Myapp.bl("spell.live", "machine-page-edn", [machine, "Myapp.Web"])
BeamLisp.Spell.Build.write_and_await(BeamLisp.Spell.Build.entry(), edn, 60_000)

# server half — generated OVER a placeholder module the router already names
source = Myapp.bl("spell.contract", "machine-module", [
  Myapp.bl("spell.machine", "contracts", [machine]),
  BeamLisp.Env.fetch!("myapp.ui.board", "module"),
  Myapp.bl("spell.live", "machine-shell", [machine])])
Code.put_compiler_option(:ignore_module_conflict, true)
Code.compile_string(source)
```

The generated module is **plumbing, deliberately**: the `use
Spacetime.LiveView` head, the `events`/`assigns`/`pushes` declarations, one
*literal* `handle_event/3` head per declared event (literal because that is
what proves to `__before_compile__` that a declared event actually reaches
the server — a catch-all only warns), one `handle_info/2` head per `on-info`
pattern. Each head delegates straight to `spell.server`. **Generating Elixir
that re-states the body would create a second copy of the logic that could
rot; generating Elixir that CALLS the body keeps exactly one.**

### Registration is a join, and boot must not learn what either side does

```elixir
for op <- BeamLisp.Env.fetch!("myapp.intent", "ops") |> Spell.Data.from_bl() do
  Server.register_performer(to_string(op), "myapp.intent/perform")
end
```

`ops` is a **var holding a vector**, so `Env.fetch!` — `Myapp.bl` would try
to *call* it and fail with a case clause showing the vector itself.

### Degrade, don't refuse to boot

A failed page publish and a failed corpus load are both **logged, not
fatal**: a node whose page will not compile still answers every check, every
test and every script, and refusing to boot takes the working half down with
the broken one. But the log must name the *consequence*, not only the cause —
"the browser will get the bundle from the last successful compile, and
nothing on the page will say so."

### The one switch tests need

Two opt-outs in the supervision tree, both false under test: `:serve` (don't
bind a port) and **`:boot`** (don't start Boot at all). The second is subtle
and was found the hard way: Boot owns the store, so a test that stops the
store to reopen the database elsewhere kills Boot, the supervisor faithfully
restarts it, and a *second* store appears on the default path — which then
holds redb's exclusive file lock against the store the test is trying to
start. Symptoms: `"Database already open. Cannot acquire lock."` in one test,
`running?` answering true immediately after a confirmed kill in another. Two
faces of a supervisor doing exactly its job.

---

## 10. Verification — four rungs, cheapest first

### (a) Domain tests, against a real store

`test/support/myapp_case.ex`. Each suite gets its **own** redb file, and
`async: false` — the store is a single registered name, so two suites sharing
one file interleave transactions and produce failures that depend on
scheduling and therefore cannot be reproduced.

Do not mock. datom runs fine over redb in a test, the file costs
milliseconds, and *a query that passes against a substitute proves something
about the substitute*.

The subtlest trap in the whole harness:

```elixir
# A FUNCTION, not `Myapp.bl("datom", "basis-t", [db()])` inline.
# The db value carries the redb handle, and a temporary in a test body stays
# reachable from that process's stack until the body returns — so a test that
# reads the basis and then kills the store finds the file still locked,
# however thoroughly it asks for a collection. Inside a function the
# reference dies on return.
def basis, do: Myapp.bl("datom", "basis-t", [db()])
```

And: a query answers a set of tuples, each tuple a beam-lisp `Vector`.
`Data.from_bl/1` converts the outer set but leaves each row a Vector, so
`assert [["Ada"]] = q(…)` fails against `%BeamLisp.Vector{items: {"Ada"}}` —
the same answer wearing the runtime's clothes. Convert rows once, in the
case template.

### (b) The machine report — static, before anything runs

`spell.machine/report` answers **data**, split by whether it blocks:

| errors (broken now) | warnings (incomplete — expected while growing) |
|---|---|
| `orphan-bindings` | `unrendered-assigns` |
| `unhandled-fires` | `unfired-events` |
| `undeclared-template-holes` | `dead-templates` |
| | `background-without-color` |

Warnings do not block: *a machine that refuses an incomplete definition
cannot be grown one definition at a time.* The same report is what a model
sees when its proposal is refused.

### (c) `scripts/check.exs` — the seam, without a browser

```
mix run --no-start scripts/check.exs
```

Drives the same path a browser drives — the generated LiveView callbacks,
`spell.server`'s walk, your performer — and asserts what comes back. Exits
non-zero on the first failure, so it is usable as a gate. It also
**publishes** the page, which is the step that catches a page that parses and
cannot run: a bind with no template, a template nothing renders, an assign
the page subscribes to and never shows.

Give it its own database, and detect the collision *by name*:

```elixir
if Process.whereis(:"myapp-store") do
  IO.puts("""
  This check needs to own its database, but the application is already
  running one. Re-run with the application stopped:

      mix run --no-start scripts/check.exs
  """)
  System.halt(1)
end
```

Without that, the failure is `{:already_started, #PID<…>}` — a message that
describes the mechanism and not the mistake. **The fix is a flag, and nobody
should have to read a supervisor's error to find it.**

The checks worth having, in order:

1. the contract and view parse
2. the machine holds both halves
3. the page compiles through spacetime
4. the contract generates a compilable server half
5. **mount computes the state WITHOUT writing** (assert the basis is unmoved)
6. an action through the seam reaches the database
7. a blank input is refused, and nothing is written
8. an illegal move is refused with a sentence

### (d) A browser

`scripts/shot.sh <page.st> <out.png>`. Rendering is the one thing the ladder
above cannot assert.

---

## 11. AOT, or your boot is 30 seconds

```elixir
compilers: Mix.compilers() ++ [:beam_lisp],
beam_lisp: [source_dir: "src"],
```

Without it every boot reads and compiles the domain from source, and the
domain requires `datom` — seventeen beam-lisp files. Measured at ~30s idle
and over three minutes under load, which is not merely slow: it is the
difference between a durability test that spawns two child VMs and one that
times out.

`:beam_lisp` goes **after** `:elixir` — the compiler task must itself be
compiled before Mix can find it.

---

## 12. The order to build in

Each step is verifiable before the next exists, which is the point of the
ordering.

| # | build | verify with |
|---|---|---|
| 1 | `schema.bl` — the attributes | a test asserting on the value |
| 2 | `work.bl` — rules as maps | pure unit tests, no store |
| 3 | `read.bl` — queries over a db value | `datom/connect` in memory |
| 4 | `store.bl` — the `defserver` | start, write, read back, restart |
| 5 | `intent.bl` — `tx-for` pure | table-driven tests, no substrate |
| 6 | `intent.bl` — `perform` + `register-reads!` | via the case template |
| 7 | `ui/board.bl` — contract only | `spell.server/handle` directly |
| 8 | `ui/board.bl` — view: markup, style, binds | `spell.machine/report` |
| 9 | `boot.ex` — registration + emission | `scripts/check.exs` |
| 10 | endpoint, router, layout | a browser |

**Steps 1–7 need no page. Steps 1–5 need no process.** That is the dividend
of "every query takes a value" and "every rule is a map": most of an
application is testable before any of it is wired.

---

## 13. Checklist of the traps, in one place

| trap | symptom | rule |
|---|---|---|
| namespaced key in a template | "undeclared hole `status`" on a `$f` template | project rows to flat, simple keys |
| a hole in `&shell` | browser paints `` `$x` `` | shell is static; mount scalars with `st/view` |
| no `st/each` for a list assign | diffs arrive, nothing renders | every list assign needs a bind |
| `do!` in a mount event | every mount raises before render | mount events `read!` |
| a reader per assign | lists from different moments | one reader, one db value |
| reusing `db` after a write | page shows the pre-write world | fresh `(store/db)` for the read-back |
| bare `catch` around a write | a failing disk reads as "somebody else changed this" | discriminate on `ex-data` keys |
| missing `datom/release!` | "Database already open. Cannot acquire lock." | release in `terminate`; idempotent |
| db value held on a test stack | same lock error, no obvious owner | read the basis inside a *function* |
| `(not (nil? (erlang/whereis n)))` | `running?` true for a dead name | compare against `:undefined` |
| `Myapp.bl` on a var | case clause showing the vector | `Env.fetch!` for values |
| `{:ok, pid} = …start!` | "no match … #PID<…>" | it returns a bare pid |
| absent attribute in a query | entity binds nothing, blocks nothing | query absence separately; absent = unsafe |
| empty list rendered bare | best result looks like a crash | compose a verdict sentence server-side |
| `Enum/*` to build a consumed stream | no streaming; buffers, or hangs on an endless upstream | build produced streams with `Stream/*` (lazy) |
| bare `@x` in a CSS value | verse refuses `value: (deref draft);` | `(inject @x)` for the reactive arrow |
| input value not bound to signal | second entry is `"firstsecond"` | bind `:value (inject @sig)` |
| `<select>` with no empty option | first action refused for a visibly-selected role | first option is `""`, and says so |
| `data-index` instead of `data-slug` | controls unwireable after a re-sort | the row carries its own identity |
| nested `st/each` in a template | "not markup" | fixed positional slots from the read model |
| `(get v i default)` past the end | browser shows the text `nil` | bound-check in the projection |
| corpus without unique-identity slug | duplicates on every boot | `:db.unique/identity`, upsert |
| suites sharing a database file | irreproducible, scheduling-dependent | one file per suite, `async: false` |
| Boot supervised while a test swaps the store | second store grabs the lock | `:boot` switch off under test |

---

## See also

- `projects/reel/` — the worked example every rule here came from
- `spell/src/spell/contract.bl` — the surface, and what each clause emits
- `spell/src/spell/server.bl` — the closed vocabulary, in one file
- `lib/beam_lisp/spell/server.ex` — where authority lives (performers,
  readers, the atom-table boundary)
- `priv/lib/datom.bl` — `q`, `pull`, `as-of`, `since`, `history`, `changes`
- `!tasks/features/FEAT-016-*` — why a write should broadcast the *moment*
  rather than the board, and what that unlocks
