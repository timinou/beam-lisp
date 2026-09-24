# A grammar of the web

You do not learn a language by memorizing every sentence. You learn a few kinds
of words and the rules for joining them, and then you can say things no one has
said before. A good drawing tool works the same way. It does not hand you a list
of finished charts; it gives you a mark, a way to map data onto that mark, and a
scale to keep it all consistent — and a bar chart turns out to be just one point
in a huge space you can reach by combining those parts.

`loom` is that idea for web apps. Instead of a box of pre-built screens, it gives
you a handful of parts that snap together. Each part is plain data. You compose
them, and the tedious machinery — the HTML, the CSS classes, the DOM updates, the
accessibility wiring — is produced for you from the parts you chose. This page
explains the parts and the one rule that ties them together.

---

## The one sentence

> **Your app is a function. It takes the current state of the world and returns a
> picture of the screen. Everything else is derived from that.**

The picture is just nested data (a "hiccup" tree — vectors and maps). Because it
is data, you can build it, test it, transform it, and diff it like any other
value. You never write instructions like "find this button and change its color."
You describe what the screen *is* for the current state, and the system figures
out the smallest set of changes to make the real page match.

This buys you three things for free, because the app is a value and not a pile of
instructions:

- **Time travel.** The world is stored as a log of facts with history built in.
  Your view is a function of that world, so showing any past state is the same
  function pointed at an earlier moment. A "rewind" slider is no extra work.
- **Real processes.** Each connected browser tab is backed by its own supervised
  process on the server. If one misbehaves, it is restarted; the rest are
  untouched.
- **Provable rules.** Because the pieces are data with clear shapes, a checker can
  prove things about them — "this view has no hidden side effects," "this balance
  never goes negative."

---

## The parts

Seven kinds of part. Learn these and you can build any screen.

### 1. Mark — the shape on the page

A mark is one node of the picture: a tag, some attributes, and children.

```clojure
[:button {:class "primary"} "Save"]
```

That is all HTML is, written as data. A mark can hold other marks, so a whole
screen is one big mark made of smaller ones.

### 2. Style — how it looks

A style is a map of visual properties. You hand it to `sx`, which hashes it into
a tiny CSS class and remembers the rule. Two identical styles anywhere in the app
collapse to the same class and one rule — no naming, no collisions, no stylesheet
to maintain.

```clojure
(sx {:color (color :accent) :padding (space :4)})   ;=> "s1a2b3"
```

Colors, spacing, radii, and type come from a **scale** — a named set of design
decisions. `(space :4)` is always the same pixels, everywhere. A brand is itself
a value you install, so recoloring the whole app is one line.

But a scale is a *floor, not a ceiling*. Every property also takes a raw value,
and a raw `:style` map always wins. You are never boxed in:

```clojure
(sx {:gap :4})                 ; the scale — the easy path
(sx {:gap "1.5rem"})           ; a raw value — whenever you want it
```

### 3. Layout — how it is arranged

There is one layout primitive, `box`, and every arrangement is a set of options
on it: a column, a row, a wrapping gallery, a grid, a centered hero, a sidebar
next to content. You do not pick a "column component" and a "row component"; you
set `:dir` and `:gap`.

```clojure
(box {:dir :row :gap :3 :align :center} a b c)     ; a row
(box {:grid :auto-fit :min-col "220px" :gap :4} …) ; a responsive grid, no media queries
```

Arrangements that change with screen size are just another option, `:at`, that
holds overrides for each breakpoint. A stack that becomes a row on wider screens
is one box:

```clojure
(box {:dir :col :at {:md {:dir :row}}} a b c)
```

Motion is a style too. `keyframes` turns a map of stops into a hashed name,
exactly as `sx` turns a map into a class, and the rule ships with the page and
with the first live patch that reaches it. A change needs no script: the view
puts the new state in a style, the patch swaps the class, and a `transition`
eases the browser from the old state to the new one.

```clojure
(sx {:animation (str (keyframes {:from {:opacity 0}}) " 400ms backwards")
     :transition "stroke-dasharray 900ms"})
```

And hover or focus styles ride along in `:on`. Layout stays one value you can
read, pass around, and transform — never a scatter of stylesheet rules.

### 4. Encoding — turning the world into a picture

This is your view function: it takes the world (and this tab's private session
state) and returns a mark. It is pure — same input, same picture — which is why
it is easy to test and safe to re-run on every change.

```clojure
(defn view [world session]
  (box {:dir :col :gap :4}
    (heading 1 "Tasks")
    (for [t (tasks world)] (task-row t))))
```

### 5. Data — where the world lives

State has exactly three homes, and no fourth to invent:

- **Shared** — the durable, historical log everyone sees.
- **Session** — this tab's private state, gone when the tab closes.
- **Local** — a plain map for view-only bits like "which panel is open."

You read the shared world with queries (datalog), which are themselves data you
can build and combine.

### 6. Event — what a click means

An interaction is not a callback function buried in the markup. It is a small
piece of data naming an intent:

```clojure
[:button {:on-click [:intent :save {:id 7}]} "Save"]
```

When it fires, that data travels to the server, which decides what becomes true.
Because the intent is data, you can inspect it, log it, replay it, and test it
without a browser. Three verbs cover the surface: `:intent` (change the shared
world), `:assign` (change this tab's state), `:navigate` (change the route).

### 7. Reconcile — making the screen match

You never touch this, but it is worth knowing it is there. When the world
changes, your view runs again and produces a new picture. The system compares the
old picture to the new one and sends the browser the shortest list of edits —
move this row, change this text — instead of redrawing everything. It is keyed, so
a reordered list moves nodes rather than rebuilding them.

---

## Why the picture being data matters

Because your screen is just nested vectors and maps, the same tools that work on
any data work on your interface. A cross-cutting change is not a framework feature
you wait for — it is a transform over a value.

- Retheme an entire subtree by walking it and swapping colors.
- Audit accessibility by *querying* the tree: "find every input with no label."
- Extend the vocabulary with your own tag that expands into more marks.
- Prove a view is pure, so no accidental side effect hides inside rendering.

The interface is not a special, walled-off thing. It is data, so everything you
already know how to do to data, you can do to it.

---

## The closed set, and why it is enough

Seven parts feel too few for "any app." They are enough because everything a
bigger framework bundles is a *combination* of these, not a new part:

| you want          | you compose                                                        |
| ----------------- | ----------------------------------------------------------------- |
| routing           | `:navigate` sets a route; the view branches on it                 |
| a form            | derive fields from a data schema; validate with a plain predicate  |
| loading states    | a view over a value that is still arriving                         |
| optimistic UI     | one event that assigns now and requests the real change next      |
| undo / redo       | point the view at an earlier moment in the log                     |

A grammar is judged by what it can say without adding a new word. This one says
all of the above with the seven parts it already has. That is the test, and it
passes.

It passes for *what can be said*. It says nothing yet about *how much to say at
once* — and that is where real screens go wrong. See the next section.

---

## Hierarchy — how much of the world one screen shows

The seven parts guarantee a screen is *correct*: every fact in the world can
reach the page. They do not stop a screen from showing every fact at once. A
view function that is pure, typed, and tested can still render nine cards on
4 000 pixels — and that is not a bug any checker finds. It is a failure of
**hierarchy**.

This section comes from a real redesign (a French banking-QA console, 2026-09).
Its detail page for one test run stacked a verdict, a causal chain, a summary,
a conversation, an expected/observed table, guardrails, a trace, a review
block, a context block and a scorer panel: 1 235 words, 4 082 px. Rebuilt with
the moves below, the same page opens at 347 words, one screen high, with
nothing deleted — every fact is still one click away.

### The rule

> **A screen answers one question. Every other question gets a link.**

The first view answers "what happened, and should I worry?". "Why?", "what
was said?", "what proves it?" are *different questions*: each deserves its own
view, reached by one gesture, never pre-rendered below the fold.

### Five moves, all composed from the seven parts

None of these is a new part. Each is a `Mark` plus a `:navigate` (or the
platform's own state), which is why they cost no session state and no script.

| move | when | how | part |
| --- | --- | --- | --- |
| **tabs** | one object, several questions | `(tabs {:active id :tabs [{:id :href :label :count}]})` — links, `?onglet=` in the URL | Mark + Navigate |
| **filter pills** | one list, several subsets | same, `:variant :pills`, a `:count` per pill | Mark + Navigate |
| **disclosure** | detail that *some* readers need | `(disclosure {:summary … :hint … :open bool} body)` — native `<details>` | Mark (browser-owned state) |
| **facts** | 3–8 attributes of one thing | `(facts {:cols 4} [[label value] …])` — a `<dl>` grid | Mark |
| **table** | many things of one kind | `(table {:columns … :rows …})` — the row's name is the link | Mark + Navigate |

**Selection belongs in the URL.** A tab or a filter is a `:navigate`, not an
`:assign`. That one choice makes the view shareable, bookmarkable, undone by
the browser's Back button, testable with a plain GET, and free of session
state. The live client already turns an in-app `<a href>` into a keyed patch,
so a tab switch repaints only what changed. Reach for `:assign` only for state
that must *not* survive a reload (a demo counter, a draft).

**Unknown selection falls back.** `?onglet=bogus` renders the first tab, never
an empty page: the parser is `(if (contains? known v) v default)`.

**Disclosure opens what the reader came for.** A fold is not a hiding place.
In a list of criteria, the *failed* and *unmeasured* ones render `:open true`;
the met ones fold. The question the screen answers decides the default.

### Subtractions — the copy a better layout deletes

Most of the words removed in that redesign were not content. They were layout
compensating for itself:

- **Section eyebrows that repeat the navigation.** "Concevoir · édition" above
  a title, when the sidebar already highlights *Concevoir*. A breadcrumb
  (`Scénarios / SCN-003`) replaces it and is also a link back.
- **Provenance on every card.** A "simulated data" badge on a page banner, the
  sidebar, each card header *and* each value. Say it once where the eye rests
  (the rail) and keep it only on the atomic values that could be mistaken for
  measurements.
- **Paragraphs that explain the mechanism.** "The position lives in the URL:
  each step is a link, therefore live navigation…" — a reader sees this by
  using it. Move such prose into a disclosure or delete it.
- **Cards inside cards.** A card of rows, each row itself a bordered, filled
  box. One surface per group; rows are separated by a hairline (`border-bottom`
  on all but `:last-child`).
- **Read-only inputs posing as forms.** A disabled field per attribute costs
  an outline, padding and a label each. A `facts` grid says the same in a
  quarter of the space and does not pretend to be editable.
- **Two buttons to the same place.** A header "Open review" *and* a card
  "See review". Keep one primary action per screen.

### What this asked of the parts

The redesign found three gaps, now closed in `loom.parts`, and one idiom worth
knowing in `loom.token`:

- `tabs` rendered only `<button role=tab>` with an `:on-select` event — state
  in the session. It now renders a `<nav>` of links (`aria-current="page"` on
  the active one) whenever an item has `:href`, with `:count` and a `:pills`
  variant. Button tabs are unchanged.
- `disclosure` and `facts` did not exist; every app re-improvised them as
  cards.
- **`sx*` can express parent state without a new selector feature.** `:on`
  emits `.cls:<pseudo>{…}`, and `:is(…)` is a pseudo-class that takes a full
  selector. So "this chevron when its `<details>` is open" is
  `{:on {"is(details[open]>summary>*)" {:transform "rotate(90deg)"}}}`, and
  "this cell unless it is in the last row" is
  `{:on {"is(tr:last-child>*)" {:border-bottom "none"}}}`. State the platform
  already tracks stays in the platform.

One more trap surfaced: a `nil` child in a hiccup vector renders fine on the
server but becomes an empty text node when the client applies a patch, which
shifts every later child index. Build optional children with `conj`/`cond->`
or filter them out; never leave a `(when …)` placeholder in a patched subtree.

---

## Where to look next

- `docs/live-architecture.md` — the whole request-to-screen loop, drawn against
  the code.
- `docs/the-application-is-a-value.md` — why a closed set of event verbs makes the
  app a value you can ship, diff, and verify.
- `priv/lib/loom/` — the parts themselves: the scale and style engine, the box layout
  algebra, and the component vocabulary built on them.
- `examples/loom/` — runnable galleries you can open in a browser, and a catalog
  that builds itself from them.
