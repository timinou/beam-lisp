// _preamble.typ — the warm-session report.
//
// The vocabulary is named for what a thing MEANS. A reader who skims only
// `#wave`, `#decision`, `#proof` and `#law` should come away with the whole
// argument; the prose is there for the parts that need arguing.
//
// One accent colour (ember) marks the warm session and nothing else. Everything
// structural is greyscale, so the accent keeps its meaning.

#let ink       = luma(18)
#let ink-soft  = luma(88)
#let ink-faint = luma(152)
#let rule      = luma(202)
#let rule-soft = luma(226)
#let wash      = luma(248)
#let wash-deep = luma(239)

#let ember      = rgb("#b4551f")
#let ember-wash = rgb("#fdf4ee")
#let moss       = rgb("#3f6b4a")

#let mono = ("JetBrains Mono", "DejaVu Sans Mono", "New Computer Modern Mono")
#let sans = ("Inter", "New Computer Modern Sans", "DejaVu Sans")

// ── the document shell ──────────────────────────────────────────────────────

#let session-doc(
  title: none,
  subtitle: none,
  kicker: none,
  dateline: none,
  standfirst: none,
  body,
) = {
  set document(title: title, author: "beam-lisp · the warm session")

  set page(
    paper: "a4",
    margin: (left: 2.3cm, right: 3.0cm, top: 2.4cm, bottom: 2.4cm),
    footer: context {
      set text(8pt, fill: ink-faint, font: sans)
      line(length: 100%, stroke: 0.4pt + rule-soft)
      v(0.35em)
      grid(
        columns: (1fr, auto),
        align(left)[#title],
        align(right)[#counter(page).display("1 / 1", both: true)],
      )
    },
  )

  set text(font: ("New Computer Modern", "Libertinus Serif"), size: 10.5pt, fill: ink)
  set par(justify: true, leading: 0.70em, spacing: 1.1em, first-line-indent: 0pt)

  show heading: set text(font: sans, weight: 600)
  show heading.where(level: 1): it => {
    v(1.6em, weak: true)
    block(width: 100%)[
      #set text(15.5pt, fill: ink)
      #it.body
      #v(0.35em)
      #line(length: 100%, stroke: 1.0pt + ink)
    ]
    v(0.8em, weak: true)
  }
  show heading.where(level: 2): it => {
    v(1.2em, weak: true)
    text(11.5pt, fill: ink, it.body)
    v(0.45em, weak: true)
  }
  show heading.where(level: 3): it => {
    v(0.9em, weak: true)
    text(10.5pt, style: "italic", weight: 500, fill: ink-soft, it.body)
    v(0.3em, weak: true)
  }

  show raw.where(block: false): it => box(
    fill: wash-deep, inset: (x: 3.5pt, y: 0pt), outset: (y: 3.5pt),
    radius: 2pt, text(9.1pt, font: mono, it),
  )
  show raw.where(block: true): it => block(
    width: 100%, fill: wash, stroke: 0.5pt + rule, radius: 2pt,
    inset: (x: 0.75em, y: 0.55em), above: 1em, below: 1.1em,
    text(8.6pt, font: mono, it),
  )

  set list(indent: 0.7em, spacing: 0.62em, marker: (text(ember)[—], text(ink-faint)[·]))
  set enum(indent: 0.7em, spacing: 0.62em)
  set table(stroke: none, inset: (x: 0.4em, y: 0.3em))

  if kicker != none {
    text(8pt, fill: ember, tracking: 1.8pt, font: sans, upper(kicker))
    v(0.45em)
  }
  text(25pt, weight: 600, font: sans, title)
  if subtitle != none {
    v(0.3em)
    block(width: 94%, text(12.5pt, fill: ink-soft, style: "italic", subtitle))
  }
  v(0.7em)
  line(length: 100%, stroke: 1.4pt + ember)
  v(0.3em)
  if dateline != none {
    set text(8pt, fill: ink-faint, font: sans)
    dateline
  }
  if standfirst != none {
    v(1.3em)
    block(width: 100%, inset: (left: 0.9em), stroke: (left: 2.4pt + ember))[
      #set text(10.8pt)
      #standfirst
    ]
  }
  v(1.4em)
  body
}

// ── semantic blocks ─────────────────────────────────────────────────────────

// A wave: one shippable piece of the plan, with what it changed and how it was
// proven. The spine of the report.
#let wave(n, title, status: "shipped", body) = {
  v(2.0em, weak: true)
  grid(
    columns: (auto, 1fr), column-gutter: 0.8em,
    align: (left + top, left + horizon),
    block(fill: ink, inset: (x: 7pt, y: 3.5pt), radius: 2pt)[
      #text(10pt, weight: 600, fill: white, font: sans)[#n]
    ],
    [
      #text(16pt, weight: 600, font: sans, title)
      #v(0.1em)
      #text(8pt, fill: ink-faint, tracking: 1.3pt, font: sans, upper(status))
    ],
  )
  v(0.7em)
  line(length: 100%, stroke: 0.8pt + ink)
  v(0.6em)
  body
}

// A decision, with the reason it was taken. The reason is mandatory: an
// assertion without one is a preference.
#let decision(what, because: none, instead: none) = block(
  width: 100%, above: 1.15em, below: 1.25em, inset: (left: 0.9em),
  stroke: (left: 2.4pt + ink),
)[
  #text(9pt, weight: 600, tracking: 0.9pt, font: sans, fill: ink-soft, upper("decision"))
  #v(0.3em, weak: true)
  #what
  #if because != none {
    v(0.35em, weak: true)
    text(9.5pt, fill: ink-soft)[*Because* — #because]
  }
  #if instead != none {
    v(0.3em, weak: true)
    text(9.5pt, fill: ink-soft)[*Instead of* — #instead]
  }
]

// An invariant. States the line the system draws, so a later change can be
// checked against it rather than re-argued.
#let law(name, body) = block(
  width: 100%, fill: ember-wash, stroke: (left: 2.4pt + ember),
  inset: (x: 0.9em, y: 0.7em), radius: (right: 2pt), above: 1.2em, below: 1.25em,
)[
  #text(8.5pt, weight: 600, tracking: 0.9pt, font: sans, fill: ember, upper("law · " + name))
  #v(0.35em, weak: true)
  #body
]

// Evidence observed in this session — a command and what it actually said.
#let proof(title, body) = block(
  width: 100%, above: 1.2em, below: 1.25em,
)[
  #grid(
    columns: (auto, 1fr), column-gutter: 0.5em,
    align: (left + horizon, left + horizon),
    text(9pt, fill: moss, weight: 600, font: sans)[✓],
    text(10pt, weight: 600, font: sans, title),
  )
  v(0.35em)
  block(width: 100%, inset: (left: 1.1em))[#body]
]

// A transcript, labelled with how to re-run it.
#let ran(cmd, body, note: none) = block(
  width: 100%, above: 1.1em, below: 1.2em,
)[
  #block(width: 100%, fill: ink, inset: (x: 0.75em, y: 0.45em), radius: (top: 2pt))[
    #text(8.4pt, fill: white, font: mono, raw("$ " + cmd))
  ]
  #block(width: 100%, fill: wash, stroke: 0.5pt + rule, inset: (x: 0.75em, y: 0.5em),
         radius: (bottom: 2pt))[
    #text(8.4pt, font: mono, body)
  ]
  #if note != none {
    v(0.3em, weak: true)
    text(8.6pt, fill: ink-faint, note)
  }
]

// A number that a reader can hold onto, with the note that makes it mean
// something.
#let measure(label, value, note: none) = block(
  width: 100%, inset: (left: 0.9em), stroke: (left: 2.4pt + ink),
  above: 1em, below: 1.1em,
)[
  #text(8pt, fill: ink-soft, tracking: 0.9pt, font: sans, upper(label))
  #v(0.15em, weak: true)
  #text(9.6pt, font: mono, value)
  #if note != none {
    v(0.2em, weak: true)
    text(8.8pt, fill: ink-faint, note)
  }
]

// A UI pane: what it shows, what a click does. Reused by the dashboard waves.
#let pane(name, shows, acts) = grid(
  columns: (0.22fr, 1fr, 0.85fr), column-gutter: 0.7em,
  align: (left + horizon, left + horizon, left + horizon),
  inset: (y: 0.32em),
  text(9.6pt, weight: 600, font: sans, name),
  text(9.4pt, shows),
  text(9.4pt, fill: ink-soft, acts),
)

// Two readings of the same thing, side by side. Used wherever "one mechanism,
// two hosts" needs showing rather than asserting.
#let contrast(left-title, left-body, right-title, right-body) = block(
  width: 100%, above: 1.2em, below: 1.3em,
)[
  #grid(
    columns: (1fr, 1fr), column-gutter: 1.1em,
    block(fill: wash, inset: 0.85em, radius: 2pt, width: 100%)[
      #text(8.5pt, weight: 600, tracking: 0.8pt, font: sans, fill: ink-soft, upper(left-title))
      #v(0.45em, weak: true)
      #set text(9.6pt)
      #left-body
    ],
    block(fill: ember-wash, inset: 0.85em, radius: 2pt, width: 100%,
          stroke: (left: 2.4pt + ember))[
      #text(8.5pt, weight: 600, tracking: 0.8pt, font: sans, fill: ember, upper(right-title))
      #v(0.45em, weak: true)
      #set text(9.6pt)
      #right-body
    ],
  )
]

// Something deliberately not built, stated precisely enough to build later.
#let gap(id: none, title: none, body) = block(
  width: 100%, stroke: (paint: ink-faint, thickness: 1pt, dash: "dashed"),
  inset: (x: 0.9em, y: 0.75em), radius: 2pt, above: 1.2em, below: 1.25em,
)[
  #if id != none or title != none {
    grid(
      columns: (auto, 1fr), column-gutter: 0.6em,
      align: (left + horizon, left + horizon),
      box(fill: ink-soft, inset: (x: 5pt, y: 2.5pt), radius: 1.5pt,
        text(7.6pt, fill: white, weight: 600, tracking: 0.5pt, font: sans, id)),
      text(10.4pt, weight: 600, font: sans, title),
    )
    v(0.5em, weak: true)
  }
  #body
]

// How the tooling ate its own cooking for this wave.
#let dogfooded(body) = block(
  width: 100%, fill: wash, inset: (x: 0.9em, y: 0.7em), radius: 2pt,
  above: 1.1em, below: 1.2em,
)[
  #text(8.4pt, weight: 600, tracking: 0.9pt, font: sans, fill: ink-soft, upper("dogfooded"))
  #v(0.35em, weak: true)
  #set text(9.8pt)
  #body
]

#let term(t) = text(weight: 600, t)
#let code(t) = raw(t)
