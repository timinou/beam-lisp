// _preamble.typ — semantic structure for the beam-lisp typing documents.
//
// Same family as docs/proof/_preamble.typ: functions are named for what a
// section MEANS, not how it looks. Greyscale-first (e-ink target); hue is
// never load-bearing. This copy is deliberately slimmed: no diagram engine,
// codly for code only.

#import "@preview/codly:1.3.0": *
#import "@preview/codly-languages:0.1.1": *

// ── greyscale palette, named by role ───────────────────────────────────────
#let ink        = luma(20)
#let ink-soft   = luma(95)
#let ink-faint  = luma(150)
#let rule-hair  = luma(190)
#let wash       = luma(247)
#let wash-deep  = luma(238)

// ── document shell ─────────────────────────────────────────────────────────
#let typing-doc(
  title: none,
  subtitle: none,
  kicker: none,
  status: none,
  dateline: none,
  body,
) = {
  set document(title: title, author: "beam-lisp design notes")

  set page(
    paper: "a4",
    margin: (left: 2.4cm, right: 3.2cm, top: 2.6cm, bottom: 2.4cm),
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

// A framed definition. Skim only these and come away with the vocabulary.
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

// A design decision with its reason. Reason is mandatory.
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

// Ground truth: a claim verified by running it this phase, with the demo
// that proves it. Distinguishes observed from believed.
#let verified(body) = block(
  width: 100%, inset: (left: 0.85em, y: 0.15em),
  stroke: (left: 2.2pt + ink-faint), below: 1.1em, above: 1.1em,
)[
  #set text(9.4pt, fill: ink-soft)
  #body
]

// Something not built yet, stated precisely enough to build.
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

// A transcript: bytes a demo actually printed, labelled with how to re-run.
#let ran(cmd, body) = block(
  width: 100%, below: 1.3em, above: 1.3em,
)[
  #block(width: 100%, fill: ink, inset: (x: 0.8em, y: 0.5em), radius: (top: 2pt))[
    #set text(8.5pt, fill: white, font: ("JetBrains Mono", "DejaVu Sans Mono"))
    #raw("$ ") #cmd
  ]
  #block(width: 100%, fill: wash, stroke: 0.5pt + rule-hair, inset: 0.8em,
         radius: (bottom: 2pt))[
    #set text(8.5pt, font: ("JetBrains Mono", "DejaVu Sans Mono"))
    #body
  ]
]

// A number that either matches or does not.
#let number(label, value) = block(
  width: 100%, inset: (left: 0.9em), stroke: (left: 2.2pt + ink),
  below: 1em, above: 1em,
)[
  #text(8.5pt, fill: ink-soft, tracking: 0.6pt, upper(label))
  #v(0.2em, weak: true)
  #text(9.5pt, font: ("JetBrains Mono", "DejaVu Sans Mono"), value)
]

// Two-column comparison.
#let contrast(left-title, left-body, right-title, right-body) = block(
  width: 100%, below: 1.3em, above: 1.3em,
)[
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

// A term being defined in place.
#let term(t) = text(weight: 600, t)
#let arrow = text(fill: ink-soft)[→]
