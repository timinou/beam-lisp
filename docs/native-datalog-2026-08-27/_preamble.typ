// Shared preamble — "Making Datalog Fast", tuned for reMarkable Paper Pro.
//
// reMarkable is a greyscale e-ink tablet: no colour, reflective (not backlit),
// portrait, ~1620×2160 at 229 DPI. So this preamble departs from the colour
// A4 house style:
//   * page sized to the device's usable area (portrait, generous margins for
//     the reader to annotate in the margin with the stylus)
//   * everything in greyscale — "colour" accents become weight + grey tone
//   * larger base text (11.5pt) and open leading — e-ink is read at arm's
//     length and thin strokes shimmer
//   * code blocks are light grey with dark ink, NOT dark-on-light inverted
//     (a big black rectangle ghosts badly on e-ink and drains contrast)
// Self-contained: no external fonts or brand deps, compiles anywhere.

#let ink    = rgb("#000000")   // pure black — max contrast on reflective paper
#let g1     = rgb("#2b2b2b")   // near-black, for strong accents
#let g2     = rgb("#555555")   // mid grey, secondary text
#let g3     = rgb("#8a8a8a")   // light grey, captions
#let hair   = rgb("#c9c9c9")   // hairlines
#let panel  = rgb("#efefef")   // code / callout fill
#let panel2 = rgb("#e4e4e4")   // table header fill

#let base-setup(body) = {
  set page(
    // reMarkable usable page — portrait, wide right margin for stylus notes.
    width: 15.6cm,
    height: 20.8cm,
    margin: (left: 1.6cm, right: 2.4cm, top: 1.7cm, bottom: 1.6cm),
    fill: white,
    numbering: "1",
  )
  set text(size: 11.5pt, fill: ink, font: ("Libertinus Serif", "DejaVu Serif", "serif"))
  set par(justify: true, leading: 0.72em, spacing: 0.9em)
  set heading(numbering: none)

  // H1 — a ruled band, black, reversed text. One per major section.
  show heading.where(level: 1): it => {
    v(0.5em)
    block(width: 100%, fill: ink, inset: (x: 9pt, y: 8pt), radius: 1pt)[
      #text(fill: white, weight: 700, size: 15pt)[#it.body]
    ]
    v(0.35em)
  }
  // H2 — bold black with a rule underneath.
  show heading.where(level: 2): it => {
    v(0.4em)
    text(fill: ink, weight: 700, size: 12.5pt)[#it.body]
    v(0.1em)
    line(length: 100%, stroke: 0.6pt + hair)
    v(0.15em)
  }
  // H3 — bold, grey.
  show heading.where(level: 3): it => { v(0.2em); text(fill: g1, weight: 700, size: 11pt)[#it.body]; v(0.1em) }

  // inline code — light box, black ink.
  show raw.where(block: false): it => box(
    fill: panel, inset: (x: 3pt, y: 0pt), outset: (y: 2.5pt), radius: 2pt,
  )[#text(fill: g1, size: 9.5pt)[#it]]
  // block code — LIGHT panel, dark ink (never inverted on e-ink).
  show raw.where(block: true): it => block(
    width: 100%, fill: panel, inset: 9pt, radius: 3pt, stroke: 0.5pt + hair,
  )[#text(fill: ink, size: 9.5pt)[#it]]

  set table(stroke: 0.5pt + hair)
  body
}

// ── A "plain words" callout — the zero-context explainer boxes. ─────────
#let plain(title, body) = block(
  width: 100%, fill: panel, inset: 10pt, radius: 3pt, stroke: (left: 3pt + ink),
  below: 10pt, above: 6pt,
)[
  #text(weight: 700, size: 10pt, fill: ink)[#title]
  #v(3pt)
  #set text(size: 10.5pt, fill: g1)
  #body
]

// ── A measured-result strip: the number, big, with its caption. ────────
#let result(headline, caption) = block(
  width: 100%, fill: white, inset: (x: 0pt, y: 4pt), below: 8pt,
)[
  #text(weight: 700, size: 13pt, fill: ink)[#headline]
  #v(1pt)
  #text(size: 9.5pt, fill: g2)[#caption]
]

// ── A verdict chip in greyscale (weight carries what colour would). ────
#let chip(label) = box(
  fill: ink, inset: (x: 5pt, y: 2pt), radius: 2pt,
)[#text(fill: white, size: 8pt, weight: 700)[#label]]

#let chip-light(label) = box(
  fill: panel2, inset: (x: 5pt, y: 2pt), radius: 2pt, stroke: 0.5pt + g3,
)[#text(fill: g1, size: 8pt, weight: 700)[#label]]

// A small caption under a figure/table.
#let cap(t) = text(size: 8.5pt, fill: g3, style: "italic")[#t]
