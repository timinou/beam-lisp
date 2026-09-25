#import "_preamble.typ": guide, idea
#import "01-meaning-and-execution.typ" as meaning
#import "02-from-source-to-regions.typ" as regions
#import "03-representations-and-values.typ" as values
#import "04-boundaries-and-lifetimes.typ" as boundaries
#import "05-a-language-wide-design.typ" as language
#import "06-building-and-checking.typ" as checking

#guide(
  title: "One Language, Many Execution Plans",
  subtitle: [A curious developer’s guide to efficient, safe execution in BEAM Lisp.],
)[

= How to use this guide

A program says what to compute. An execution plan says how to compute it.
Keeping those ideas separate lets a language preserve its meaning while using
more efficient loops, representations, and machine code.

This guide explains that separation in BEAM Lisp. You can read it in order or
start with the question that interests you:

- *Why can the same program run in several ways?* Start with chapter 1.
- *What does a compiler need to know before fusing a pipeline?* Read chapter 2.
- *Which data structures make those transformations practical?* Read chapter 3.
- *What keeps native execution safe for the VM and its callers?* Read chapter 4.
- *How does this scale beyond a byte loop?* Read chapter 5.
- *How do I build and check an extension?* Work through chapter 6.

#idea(title: "A useful reading convention")[
  A *design recipe* describes a facility to build or generalise. Executable
  examples use the repository’s present BL interfaces. Illustrative IR and
  proposed interfaces are labelled where they appear, so you can distinguish
  a runnable example from a compiler-extension exercise.
]

You need a little familiarity with functions and collections. Terms such as
“region”, “layout”, “NIF”, and “dirty scheduler” are introduced as they become
useful. The code examples are BL. Paths are relative to the repository root.

The executable byte-pipeline and direct-entry examples are in
`research/rt-selfhost/fusion/` and `research/rt-selfhost/invm/`. Their result
files contain commands, input domains, raw timing samples, and verification
receipts. This guide concentrates on the reasoning you can reuse.

To compile the complete guide from the repository root:

```sh
typst compile --root . docs/native-regions/main.typ guide.pdf
```

Each numbered chapter is also a standalone Typst document. Use the same
`--root .` option when compiling a chapter on its own.

#pagebreak()
#outline(title: [Contents], depth: 2)
#pagebreak()
#meaning.chapter
#pagebreak()
#regions.chapter
#pagebreak()
#values.chapter
#pagebreak()
#boundaries.chapter
#pagebreak()
#language.chapter
#pagebreak()
#checking.chapter
]
