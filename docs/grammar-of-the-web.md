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
