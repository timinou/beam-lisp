# The explorer

A library is a set of functions. Examples are how you learn them. The explorer
puts the two side by side and answers one question, live in your browser: **which
functions does an example actually show, and which does no example show at all?**

It works for any beam-lisp library. Point it at a folder of source and a folder
of examples. It reads both, and tells you where the gaps are — the functions a
newcomer could never learn, because nothing demonstrates them.

---

## The one idea

Everything the explorer shows is a **query over a small database it builds from
your code**. It reads two things:

- a **library** — every public function it exports, one row per function
- a set of **examples** — every demo, and the functions each demo calls

Then it joins them. A function is *demonstrated* when some example calls it by
name. A function no example calls is a *gap*. Coverage is just the count of one
against the other. Nothing is hand-maintained; change a file, re-run, and every
number updates itself.

Because it is all data, the same code that measures `loom` measures any library.
`loom` is simply the first one it points at.

---

## Run it

```
mix beam_lisp.run --path priv tooling/run-catalog.bl
```

Open <http://127.0.0.1:4050>. Give it about a minute the first time — it reads
every file and warms the styles before it serves.

You see a list of groups on the left and live examples on the right. Click a
group to switch; type in the search box to filter. At the top of the list sits
**◈ Self** — the explorer measuring itself.

---

## Point it at your own library

Two environment variables choose what to explore:

```
BL_CATALOG_LIB=path/to/lib \
BL_CATALOG_DIR=path/to/examples \
mix beam_lisp.run --path priv tooling/run-catalog.bl
```

- `BL_CATALOG_LIB` — the folder of source files whose public functions you want
  to measure. Defaults to `priv/loom`.
- `BL_CATALOG_DIR` — the folder of example files that demonstrate them. Defaults
  to `examples/loom`.

Your example files must be on the load path so their `:require`s resolve. The
simplest way is to keep the library under `priv/` and run with `--path priv`, the
way `loom` does.

---

## What an example is

An example is an ordinary function carrying a `^:catalog` tag. The tag holds the
group it belongs to, its title, and a one-line description:

```clojure
(defn ^{:catalog {:group "Inputs" :title "Button"
                  :doc "The workhorse action button."}}
  demo-button []
  (ui/button {:variant :primary} "Save"))
```

The body is the live demo. The tag is its documentation. They are the same
function, so they can never drift apart. The explorer finds these tags, renders
each body, and lists the functions the body calls — that last part is what turns
into coverage.

A function without a `^:catalog` tag is still counted, as *undocumented*. The
count sits quietly at the bottom of the group list, so you always know how much
of your own showcase is unlabelled.

---

## Reading the Self panel

Click **◈ Self**. Every card here is a query over the explorer's own database.

- **Primitive coverage** — one bar for the whole library, then one per module.
  Green is well-covered, amber is partial, red is thin. The number reads
  `shown / total`.
- **Coverage by thread** — the same coverage seen along a different axis (see
  *Threads* below). This card only appears when your library declares threads.
- **Undemonstrated primitives** — the gap, named. Every public function no
  example calls. Each one is asking for a demo.
- **Health** — static checks over your examples: rendered lists missing a `:key`,
  and inputs an assistive-technology user could not label. A clean bill shows a
  green check.
- **Composition** — pairs of functions that appear together in one example. This
  is your library composing itself, measured.

---

## Threads (optional)

A module answers "which file is a function in". A **thread** answers "which
*concern* does it serve" — a cross-cutting axis that does not follow the file
layout. `loom` weaves seven: mark, style, layout, encoding, data, event,
reconcile. A layout function serves `layout`; a component serves both `mark` and
`style`.

Threads let you ask "is every part of the *event* concern demonstrated?" even
though event-handling functions live in several files. A function may serve more
than one thread, so it counts toward each.

Threads are a property of the library being explored, not of the tool. `loom`
declares its own; a library that declares none simply has no thread card — the
explorer measures everything else and quietly drops the axis. To give a single
function its own threads, tag it at the source:

```clojure
(defn ^{:thread [:layout :style]} row [& kids] …)
```

---

## Why the numbers are honest

Coverage counts one thing only: does an example call this function *by name*?

Calling it *indirectly* does not count. If every demo uses a layout helper that
happens to read a colour token, the colour token still reads as uncovered —
because no demo shows the token itself. A 0% module is a true, useful signal: it
says "write a demo that uses these directly", never "you are done". The explorer
never inflates a number to look greener than the code is.

---

## Where it lives

- `tooling/catalog.bl` — the engine: reads source, builds the database, answers
  every query, renders the live view.
- `tooling/run-catalog.bl` — the entrypoint that indexes the default package and
  serves it.
- `priv/live/lint.bl` — the static check for rendered lists missing a `:key`,
  which also runs once at start and prints any findings before serving.
- `examples/loom/` — the galleries that demonstrate `loom`, and the model for how
  to write examples the explorer can read.
