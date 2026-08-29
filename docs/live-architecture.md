# beam-lisp live — the whole loop, schematically

This is the architecture of a live beam-lisp app, drawn against the real code.
Every box maps to a file you can open. The running example is
`examples/live/11-pulse-app.bl` (Pulse, a team check-in app); read this and it
side by side.

The one idea, before the diagrams:

> **The frontend is a pure function of the world. The backend decides what
> becomes true. They meet at the database.** A click does not mutate the screen
> — it requests a *fact*. The fact commits to a log; every viewer re-projects
> from the new coordinate and receives only the *difference*.

---

## 1. The layers (what lives where)

```
                          priv/live/
  ┌──────────────────────────────────────────────────────────────────┐
  │  style.bl   design tokens + atomic CSS   ── a brand, as a value    │
  │  ui.bl      accessible components         ── functions → hiccup     │
  │  hiccup.bl  hiccup → HTML string          ── the render primitive   │
  │  diff.bl    keyed structural diff → ops   ── the minimal-patch core  │
  │  socket.bl  defview · deflive · the loop  ── binds a view to a conn  │
  │  client.js  applies ops to the real DOM   ── the browser half        │
  └──────────────────────────────────────────────────────────────────┘
                                │  rests on
                                ▼
                          priv/datom/  (the log-structured database)
                          priv/auth.bl (the guard + the authorizer)
```

Nothing in the view layer knows about sockets; nothing in the socket layer
knows about HTML. Each layer is a pure transform over the one below.

---

## 2. State — there are exactly three kinds, and no more

The hardest question in any UI framework is "where does state live?" Here the
answer is closed. Three kinds, each with one home:

```
  kind         lives in                      lifetime            example
  ──────────   ───────────────────────────   ─────────────────   ─────────────────
  SHARED    →  the shared datom conn         durable, the log    a check-in fact
  SESSION   →  a per-socket in-memory conn   dies with the tab   a draft note
  LOCAL     →  the socket's :locals map      dies with the tab   who am I (:me)
```

- **shared** is the truth everyone sees. It is a fact in the log; it has
  `q`, `pull`, `as-of`, `watch` — and history — for free.
- **session** is *this viewer's* private database. Same datom API, but the ETS
  table is owned by the socket process, so it is reclaimed when the tab closes
  — leak-free by process lifetime, no cleanup code.
- **local** is a plain map for scalars (route, role, identity).

There is no fourth "component state" tier to invent. Durable/shared → it's a
fact. Ephemeral/private → it's a session datom or a local. That's it.

---

## 3. The loop — one commit, N viewers converge

This is the whole thing. Follow the numbers.

```
   Bo's browser                    the server (one gen_server per viewer)
  ┌──────────────┐                ┌───────────────────────────────────────────┐
  │              │  ①  [:event    │  socket.bl  handle-event                    │
  │  a click on  │──── :intent ──▶│    │                                        │
  │  a button    │   :checkin]    │    ② auth.bl  authorize(principal, ctx)     │
  │              │                │    │      allow? ──no──▶ push [:denied]  ✗   │
  │              │                │    │      yes                                │
  │              │                │    ▼                                        │
  │              │                │    ③ intent handler → a tx (WHO from auth)  │
  │              │                │    │                                        │
  │              │                │    ▼                                        │
  │              │                │    ④ datom/transact!  ─────────┐            │
  └──────────────┘                └───────────────────────────────│───────────┘
                                                                   │ commit
                                             the shared datom log  ▼
                                          ┌───────────────────────────────────┐
                                          │  ⑤ [:datom/tx basis] broadcast     │
                                          └───┬───────────────────────────┬────┘
                                              │ every listening socket    │
                        ┌─────────────────────▼──────┐   ┌────────────────▼─────────────┐
                        │  Ada's socket handle-info   │   │  Bo's socket handle-info      │
                        │   ⑥ next = view(db, …)      │   │   ⑥ next = view(db, …)        │
                        │   ⑦ ops  = diff(tree, next) │   │   ⑦ ops  = diff(tree, next)   │
                        │   ⑧ push [:patch ops] ──────┼─┐ │   ⑧ push [:patch ops] ──────┼─┐
                        └─────────────────────────────┘ │ └───────────────────────────────┘ │
                                                         ▼                                   ▼
                                              Ada's browser                        Bo's browser
                                           ⑨ client.js applyOp(root, op)   ⑨ client.js applyOp(root, op)
                                              (DOM grows by exactly the        (same minimal patch)
                                               new row + the count text)
```

The crucial inversion is between ① and ⑧: **the click does not render Bo's
screen.** It commits a fact. Bo's screen updates on the *same path* as Ada's —
through the log (⑤→⑥→⑦→⑧). So two tabs cannot disagree, and a dropped patch is
recoverable by re-projecting from the basis. LiveView's `handle_event` renders
in the one process that received the click; here the loop closes through a
durable, ordered log.

An `[:assign …]` (a local edit — typing in the draft field) is the *only* thing
that renders inline: it touches session/local state no other viewer cares
about, so it short-circuits ①→⑧ for just this socket.

---

## 4. A view is a pure projection (the frontend, exactly)

```
   view : (shared-db, session-db, locals) → hiccup

   ┌── shared-db ──┐   ┌── session-db ─┐   ┌── locals ──┐
   │ team checkins │   │ my draft note │   │ :me "ada"  │
   └───────┬───────┘   └───────┬───────┘   └─────┬──────┘
           │                   │                 │
           └─────────┬─────────┴────────┬────────┘
                     ▼                   ▼
              live.ui components   (auth.bl guard scopes the
              (card, badge, field,  shared query BEFORE it runs:
               button, stack…)      a forbidden row is never
                     │              selected — absent, not filtered)
                     ▼
                  hiccup  ── [:main [:section [:article {:key …} …]]]
                     │
             ┌───────┴────────┐
             ▼                ▼
      hiccup→html        diff(old,new)
      (first paint)      (every update → keyed patch ops)
```

Because `view` is a pure function of *values*, you test a whole screen with
`=` and no socket:

```clojure
(= expected-tree (view test-db nil {:me "ada"}))
```

The design system rides along: `(s/install-theme! brand)` at the top of the
view means every component paints in the app's brand, because each reads its
colour/space/type through `tok` — a token lookup, not a hardcoded value.

---

## 5. The diff is why it's fast (and honest)

A commit re-runs the view and diffs the *tree*, not rendered strings. Keys make
the diff minimal and truthful:

```
   old feed                        new feed (Bo just checked in)
   [:ul                            [:ul
     [:li {:key "c001"} …ada]        [:li {:key "c002"} …bo]     ← new
     ]                                [:li {:key "c001"} …ada]]

   diff →  [[:text  [0 0] "2 today"]          ← the count badge changed
           [:insert [1] "c002" 0 [:li …bo]]]  ← one keyed row inserted

   NOT a re-render. Exactly the two things that changed.
```

A reorder emits `:move` (the DOM node is *kept*, not rewritten) — the property a
string diff structurally cannot express. `apply-ops` in `diff.bl` is the
reference semantics; `client.js` is a line-for-line port, so what the test
asserts headless is what the browser does.

---

## 6. Auth is the same datalog as the view (not a bolted-on layer)

```
   the VIEW (read side)                the WRITE (intent side)
   ─────────────────────               ────────────────────────
   auth/guard injects a                socket authorizes an intent
   conjunctive :where clause           BEFORE transact!:
   → a viewer literally cannot         → allow? commit stamped with
     render a row they may not           the real principal
     see (the store never              → deny?  push [:denied why];
     selects it)                         the log is never touched

               ╲                     ╱
                ╲   the deep point   ╱
                 ▼                  ▼
   a guard clause is CONJUNCTIVE ⇒ MONOTONE. The very property that makes an
   incremental live view SOUND (live.bl only drives incremental diffs for
   monotone queries) is the property that makes it SECURE. One idea, two
   guarantees, zero extra machinery.
```

`WHO` acted is the authenticated principal the socket carries — the client
names the *intent*, never the actor. A check-in cannot lie about who checked in.

---

## 7. The file-to-concept map (open these next to the example)

```
  concept in the loop          file                       key symbol
  ─────────────────────        ──────────────────────     ─────────────────────
  brand as a value             priv/live/style.bl         install-theme!, tok, sx
  accessible components        priv/live/ui.bl            button, field, card…
  view → HTML                  priv/live/hiccup.bl        hiccup->html
  minimal patches              priv/live/diff.bl          diff, apply-ops
  bind view ↔ conn (the loop)  priv/live/socket.bl        defview, deflive,
                                                          mount, on-commit,
                                                          handle-event
  browser applies patches      priv/live/client.js        Live.applyOp
  the shared world + history   priv/datom/                connect, transact!,
                                                          q, as-of, listen!
  guard + authorizer           priv/auth.bl               guard, authorize
  the running app              examples/live/11-pulse-app.bl
```

---

## 8. Why this is more than a LiveView clone

| question                          | this stack's answer                          |
|-----------------------------------|----------------------------------------------|
| where is state?                   | three closed kinds (shared/session/local)    |
| what is an event?                 | a **fact request** (data), not a closure     |
| how do two tabs agree?            | they re-project from one **log**, not msgs   |
| how is a view tested?             | call it with `=` — it's a pure function      |
| how is the diff minimal?          | keyed **tree** diff, `:move` keeps DOM nodes |
| where does authorization live?    | the **same datalog** as the query            |
| why is incremental diff safe?     | monotone guard ⇒ sound **and** secure        |
| can you see the past?             | `as-of` — the view is `db→hiccup`, so free   |
| where does per-viewer state go?   | a session datom conn, self-cleaning          |

The frontend is a projection. The backend is a decision about what becomes
true. The database is where they meet — and it remembers.
