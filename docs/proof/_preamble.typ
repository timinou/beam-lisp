// _preamble.typ — semantic structure for the Spell architecture notes.
//
// The functions here are named for what a section MEANS, not how it looks.
// `#gap[]` is not "a red box"; it is "a thing that does not exist yet, stated
// precisely enough to build". If a later document needs a different visual for
// gaps, it changes here and every gap in every document follows.
//
// Target: reMarkable Paper Pro (11.8" e-ink, greyscale, 229 DPI).
// Consequences, which drive every visual choice below:
//   - no colour. Hue must never be load-bearing; weight/rule/indent carry it.
//   - slow refresh. Layout is quiet: no heavy fills, no rainbow admonitions.
//   - read with a pen in hand. Generous margins for marginalia.

#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
#import "@preview/codly:1.3.0": *
#import "@preview/codly-languages:0.1.1": *

// ── greyscale palette ──────────────────────────────────────────────────────
// Named by ROLE, not by shade, so the intent survives a palette change.
#let ink        = luma(20)
#let ink-soft   = luma(95)
#let ink-faint  = luma(150)
#let rule-hair  = luma(190)
#let wash       = luma(247)
#let wash-deep  = luma(238)

// ── document shell ─────────────────────────────────────────────────────────
#let spell-doc(
  title: none,
  subtitle: none,
  kicker: none,
  status: none,
  dateline: none,
  body,
) = {
  set document(title: title, author: "Spell architecture notes")

  // e-ink: wide outer margin is a feature — it is where the reader writes.
  set page(
    paper: "a4",
    margin: (left: 2.4cm, right: 3.4cm, top: 2.6cm, bottom: 2.4cm),
    footer: context {
      set text(8.5pt, fill: ink-faint)
      line(length: 100%, stroke: 0.4pt + rule-hair)
      v(0.4em)
      grid(
        columns: (1fr, auto),
        align(left)[#title],
        align(right)[#counter(page).display("1")],
      )
    },
  )

  set text(font: ("New Computer Modern", "Libertinus Serif"), size: 10.5pt, fill: ink)
  set par(justify: true, leading: 0.72em, spacing: 1.15em, first-line-indent: 0pt)

  show heading: set text(font: ("Inter", "New Computer Modern Sans"), weight: 600)
  show heading.where(level: 1): it => {
    v(1.5em, weak: true)
    block(width: 100%)[
      #set text(15pt, fill: ink)
      #it.body
      #v(0.35em)
      #line(length: 100%, stroke: 0.9pt + ink)
    ]
    v(0.75em, weak: true)
  }
  show heading.where(level: 2): it => {
    v(1.15em, weak: true)
    text(11.8pt, fill: ink, it.body)
    v(0.45em, weak: true)
  }
  show heading.where(level: 3): it => {
    v(0.9em, weak: true)
    text(10.5pt, style: "italic", weight: 500, fill: ink-soft, it.body)
    v(0.3em, weak: true)
  }

  show raw.where(block: false): it => box(
    fill: wash-deep, inset: (x: 3.5pt, y: 0pt), outset: (y: 3.5pt),
    radius: 2pt, text(9.2pt, it),
  )

  show: codly-init.with()
  codly(
    languages: codly-languages,
    zebra-fill: none,
    fill: wash,
    stroke: 0.5pt + rule-hair,
    inset: (x: 0.5em, y: 0.32em),
    radius: 2pt,
    number-format: none,
  )

  set list(indent: 0.7em, spacing: 0.7em, marker: (text(ink-faint)[•], text(ink-faint)[–]))
  set enum(indent: 0.7em, spacing: 0.7em)
  set table(stroke: none)

  // ── title block ──
  if kicker != none {
    text(8.5pt, fill: ink-faint, tracking: 1.6pt, upper(kicker))
    v(0.5em)
  }
  text(24pt, weight: 600, font: ("Inter", "New Computer Modern Sans"), title)
  if subtitle != none {
    v(0.35em)
    block(width: 92%, text(12.5pt, fill: ink-soft, style: "italic", subtitle))
  }
  v(0.7em)
  line(length: 100%, stroke: 1.1pt + ink)
  v(0.35em)
  if status != none or dateline != none {
    set text(8.5pt, fill: ink-faint)
    grid(
      columns: (1fr, auto),
      align(left)[#status], align(right)[#dateline],
    )
  }
  v(1.6em)

  body
}

// ── semantic blocks ────────────────────────────────────────────────────────
// Each carries one meaning. The visual is an argument about that meaning.

// A framed statement of what a thing IS. The reader should be able to skim
// only these and come away with the definitions.
#let idea(title: none, body) = block(
  width: 100%, fill: wash, stroke: (left: 2.2pt + ink), inset: (x: 1em, y: 0.85em),
  radius: (right: 2pt), below: 1.3em, above: 1.3em,
)[
  #if title != none {
    text(9pt, weight: 600, tracking: 0.4pt, fill: ink, upper(title))
    v(0.45em, weak: true)
  }
  #body
]

// A GAP: something that does not exist yet. Dashed border — deliberately
// unfinished-looking. This is the document's most important block type; the
// whole point is to state absences as precisely as facts.
#let gap(id: none, title: none, body) = block(
  width: 100%, stroke: (paint: ink-soft, thickness: 1pt, dash: "dashed"),
  inset: (x: 1em, y: 0.9em), radius: 2pt, below: 1.3em, above: 1.3em,
)[
  #if id != none or title != none {
    grid(
      columns: (auto, 1fr), column-gutter: 0.6em, align: (left + horizon, left + horizon),
      if id != none {
        box(fill: ink, inset: (x: 5pt, y: 2.5pt), radius: 1.5pt,
          text(8pt, fill: white, weight: 600, tracking: 0.5pt, id))
      },
      if title != none { text(10.5pt, weight: 600, title) },
    )
    v(0.55em, weak: true)
  }
  #body
]

// Ground truth: a claim verified against the repo THIS session. Distinguishes
// what was observed from what is believed — the honesty boundary, made visual.
#let verified(body) = block(
  width: 100%, inset: (left: 0.85em, y: 0.15em),
  stroke: (left: 2.2pt + ink-faint), below: 1.1em, above: 1.1em,
)[
  #set text(9.4pt, fill: ink-soft)
  #body
]

// A correction to something previously believed. Honesty artifact: the doc
// records where the earlier reading was wrong, rather than quietly restating.
#let correction(body) = block(
  width: 100%, fill: wash-deep, inset: (x: 1em, y: 0.8em), radius: 2pt,
  stroke: (left: 2.2pt + ink), below: 1.3em, above: 1.3em,
)[
  #text(8.5pt, weight: 600, tracking: 1pt, fill: ink)[CORRECTION]
  #v(0.4em, weak: true)
  #body
]

// A design decision with its reason. Reason is mandatory: a decision without
// one is not a decision, it is a preference.
#let decision(body, because: none) = block(
  width: 100%, below: 1.2em, above: 1.2em, inset: (left: 0.9em),
  stroke: (left: 2.2pt + ink),
)[
  #body
  #if because != none {
    v(0.4em, weak: true)
    text(9.4pt, fill: ink-soft)[*Because* — #because]
  }
]

// An open question for the reader. This is a thinking document; questions
// are first-class content, not an afterthought at the end.
#let question(body) = block(
  width: 100%, inset: (x: 1em, y: 0.8em), radius: 2pt,
  stroke: 0.8pt + ink-soft, below: 1.3em, above: 1.3em,
)[
  #grid(columns: (auto, 1fr), column-gutter: 0.7em,
    text(13pt, weight: 600, fill: ink)[?],
    body,
  )
]

// Inline judgement marks. Meaning first, glyph second.
#let yes = text(fill: ink, weight: 700)[✓]
#let no = text(fill: ink, weight: 700)[✗]
#let arrow = text(fill: ink-soft)[→]

// A term being defined in place.
#let term(t) = text(weight: 600, t)

// Two-column comparison. Used for "what jank did / what this does".
#let contrast(left-title, left-body, right-title, right-body) = block(
  width: 100%, below: 1.3em, above: 1.3em,
)[
  // NB: no `height: 100%` on these cells. Inside a grid row that resolves
  // against the PAGE, not the row, so each panel stretched to the full page
  // height and left a column of empty grey. Let the content size the boxes.
  #grid(
    columns: (1fr, 1fr), column-gutter: 1.1em,
    block(fill: wash, inset: 0.85em, radius: 2pt, width: 100%)[
      #text(8.5pt, weight: 600, tracking: 0.8pt, fill: ink-soft, upper(left-title))
      #v(0.45em, weak: true)
      #set text(9.6pt)
      #left-body
    ],
    block(fill: wash, inset: 0.85em, radius: 2pt, width: 100%,
          stroke: (left: 2.2pt + ink))[
      #text(8.5pt, weight: 600, tracking: 0.8pt, fill: ink, upper(right-title))
      #v(0.45em, weak: true)
      #set text(9.6pt)
      #right-body
    ],
  )
]

// A labelled figure caption for diagrams.
#let stage-note(body) = align(center, block(width: 88%,
  text(9pt, fill: ink-soft, style: "italic", body)))

// ── proof-specific blocks ──────────────────────────────────────────────────
// This document's job is EVIDENCE, so it needs a way to say "this is the
// literal output of a command" distinctly from "this is what I claim".

// A transcript: bytes a command actually printed. Monospace, framed, and
// labelled with the command, so a reader can re-run it.
// A transcript. `body` is passed through `raw`, so a `$` is a dollar sign and a
// backslash is a backslash — a document quoting shell output must not reinterpret
// it, or the evidence is no longer what the command printed.
#let ran(cmd, body) = block(
  width: 100%, below: 1.3em, above: 1.3em,
)[
  #block(width: 100%, fill: ink, inset: (x: 0.8em, y: 0.5em), radius: (top: 2pt))[
    // NB the prompt is a raw literal: a bare `$` opens MATH MODE in Typst and
    // swallows the rest of the block.
    #set text(8.5pt, fill: white, font: ("JetBrains Mono", "DejaVu Sans Mono"))
    #raw("$ ") #cmd
  ]
  #block(width: 100%, fill: wash, stroke: 0.5pt + rule-hair, inset: 0.8em,
         radius: (bottom: 2pt))[
    #set text(8.5pt, font: ("JetBrains Mono", "DejaVu Sans Mono"))
    #body
  ]
]

// A screenshot with its provenance. An image without a caption saying how it
// was produced is decoration, not evidence.
#let shot(path, caption) = block(width: 100%, below: 1.4em, above: 1.2em)[
  #block(width: 100%, stroke: 0.8pt + rule-hair, radius: 2pt, clip: true,
    image(path, width: 100%))
  #v(0.4em)
  #align(center, block(width: 92%, text(8.5pt, fill: ink-soft, style: "italic", caption)))
]

// A defect found by running. The document argues that some bugs are only
// visible this way, so they get their own visual identity.
#let caught(title, body) = block(
  width: 100%, fill: wash-deep, inset: (x: 1em, y: 0.85em), radius: 2pt,
  stroke: (left: 2.2pt + ink), below: 1.3em, above: 1.3em,
)[
  #text(8.5pt, weight: 600, tracking: 1pt, fill: ink)[CAUGHT BY RUNNING IT]
  #v(0.35em, weak: true)
  #text(10.5pt, weight: 600, title)
  #v(0.4em, weak: true)
  #body
]

// A number that either matches or does not. No interpretation possible.
#let number(label, value) = block(
  width: 100%, inset: (left: 0.9em), stroke: (left: 2.2pt + ink),
  below: 1em, above: 1em,
)[
  #text(8.5pt, fill: ink-soft, tracking: 0.6pt, upper(label))
  #v(0.2em, weak: true)
  #text(9.5pt, font: ("JetBrains Mono", "DejaVu Sans Mono"), value)
]
