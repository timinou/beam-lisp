// _preamble.typ — house style + semantic blocks for the EDN⇄Spacetime MVP spec.
// Imported once by main.typ via `#show: conf`. Parts import the block functions.
//
// Semantic vocabulary:
//   conf          document template (apply with #show: conf)
//   note / risk / decision / invariant / openq   callout blocks
//   req           numbered requirement (Spacetime improvement or MVP requirement)
//   module        module card: name, layer, owns/disowns, purpose
//   xp            MVP experience walkthrough block
//   stage         roadmap stage (MVP / fast-follow / later)
//   defn          glossary entry
//   term          inline terminology mark
//   bl / st / edn fenced code helpers (beam-lisp, spacetime, edn)

#import "@preview/codly:1.3.0": *
#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge

// ── palette ──────────────────────────────────────────────────────────────
// tint(c, p): p% white mixed into c (stands in for c.lerp(white, p))
#let tint(c, p) = color.mix((white, p), (c, 100% - p))
#let ink      = rgb("#1a1b26")
#let accent   = rgb("#7aa2f7")   // edn / beam-lisp side
#let accent2  = rgb("#bb9af7")   // spacetime side
#let seamc    = rgb("#e0af68")   // the seam between them
#let goodc    = rgb("#2a9d6f")
#let riskc    = rgb("#c04b5a")
#let mutec    = rgb("#565f89")
#let panelbg  = rgb("#f4f5fa")

// ── document template ────────────────────────────────────────────────────
#let conf(body) = {
  set document(title: "The Spell Duet — EDN⇄Spacetime MVP", author: "ora")
  set page(
    paper: "a4",
    margin: (x: 2.2cm, y: 2.4cm),
    numbering: "1",
    header: context {
      if counter(page).get().first() > 1 {
        set text(size: 8pt, fill: mutec)
        [The Spell Duet — EDN⇄Spacetime MVP #h(1fr) #emph[spec]]
      }
    },
  )
  set text(font: "New Computer Modern", size: 10.5pt, lang: "en")
  set par(justify: true, leading: 0.62em)
  set heading(numbering: "1.1")
  show heading.where(level: 1): it => {
    v(1.2em, weak: true)
    block(
      below: 0.9em,
      text(size: 15pt, weight: "bold", fill: ink)[
        #counter(heading).display() #h(0.4em) #it.body
      ],
    )
  }
  show heading.where(level: 2): it => {
    v(0.8em, weak: true)
    text(size: 12pt, weight: "bold", fill: accent.darken(35%), it)
    v(0.15em, weak: true)
  }
  show heading.where(level: 3): it => {
    v(0.6em, weak: true)
    text(size: 10.5pt, weight: "bold", fill: ink, it)
  }
  show raw.where(block: true): set text(size: 8.2pt)
  show raw.where(block: false): it => box(
    fill: panelbg, outset: (x: 2.5pt, y: 1.5pt), radius: 2pt,
    text(size: 8.6pt, it),
  )
  show link: it => text(fill: accent.darken(25%), it)
  show: codly-init.with()
  codly(
    languages: (
      clojure: (name: "beam-lisp", color: accent.darken(30%)),
      spacetime: (name: "spacetime", color: accent2.darken(30%)),
      edn: (name: "edn", color: seamc.darken(20%)),
      kdl: (name: "kdl", color: mutec),
      elixir: (name: "elixir", color: accent2.darken(30%)),
      text: (name: "text", color: mutec),
    ),
    header-transform: it => text(size: 7.5pt, fill: mutec, it),
  )
  body
}

// ── callouts ─────────────────────────────────────────────────────────────
#let _callout(stroke, fill, tag, tagfill, body) = block(
  width: 100%,
  inset: (x: 10pt, y: 8pt),
  radius: 3pt,
  stroke: (left: 2.5pt + stroke, rest: 0.4pt + tint(stroke, 60%)),
  fill: fill,
  below: 1em,
)[
  #text(size: 8pt, weight: "bold", fill: tagfill, tracking: 0.06em, tag)
  #v(2pt, weak: true)
  #body
]

#let note(body)      = _callout(mutec,  tint(mutec, 94%),  [NOTE],      mutec, body)
#let risk(body)      = _callout(riskc,  tint(riskc, 94%),  [RISK],      riskc, body)
#let decision(body)  = _callout(goodc,  tint(goodc, 93%),  [DECISION],  goodc.darken(15%), body)
#let invariant(body) = _callout(seamc,  tint(seamc, 93%),  [INVARIANT], seamc.darken(25%), body)
#let openq(body)     = _callout(accent2, tint(accent2, 93%), [OPEN QUESTION], accent2.darken(25%), body)

// ── requirement block ────────────────────────────────────────────────────
// status: "assumed" (plan implemented upstream), "new" (this spec requires it)
#let req(id, title, status: "new", body) = block(
  width: 100%,
  inset: (x: 10pt, y: 8pt),
  radius: 3pt,
  stroke: 0.4pt + tint(mutec, 40%),
  fill: panelbg,
  below: 1em,
)[
  #grid(
    columns: (auto, 1fr, auto),
    gutter: 8pt,
    text(weight: "bold", fill: accent.darken(35%))[#id],
    text(weight: "bold")[#title],
    {
      let (label, c) = if status == "assumed" {
        ([ASSUMED IMPLEMENTED], goodc.darken(10%))
      } else if status == "new" {
        ([NEW — THIS SPEC], seamc.darken(25%))
      } else {
        ([#status], mutec)
      }
      box(fill: tint(c, 88%), radius: 2pt, outset: (x: 4pt, y: 1.5pt),
          text(size: 7.5pt, weight: "bold", fill: c, label))
    },
  )
  #v(3pt, weak: true)
  #body
]

// ── module card ──────────────────────────────────────────────────────────
#let module(name, layer, owns: none, disowns: none, body) = block(
  width: 100%,
  inset: (x: 10pt, y: 8pt),
  radius: 3pt,
  stroke: (left: 2.5pt + accent, rest: 0.4pt + tint(mutec, 55%)),
  fill: white,
  below: 1em,
)[
  #text(weight: "bold", size: 11pt)[#name]
  #h(6pt)
  #box(fill: tint(accent, 85%), radius: 2pt, outset: (x: 4pt, y: 1.5pt),
       text(size: 7.5pt, weight: "bold", fill: accent.darken(35%), layer))
  #v(3pt, weak: true)
  #body
  #if owns != none [
    #v(3pt, weak: true)
    #text(size: 8.5pt)[*owns:* #owns]
  ]
  #if disowns != none [
    #v(1pt, weak: true)
    #text(size: 8.5pt, fill: mutec)[*deliberately not:* #disowns]
  ]
]

// ── MVP experience walkthrough ───────────────────────────────────────────
#let xp(n, title, body) = block(
  width: 100%,
  below: 1em,
)[
  #grid(
    columns: (28pt, 1fr),
    gutter: 10pt,
    align: top,
    box(
      width: 24pt, height: 24pt, radius: 50%,
      fill: tint(seamc, 80%),
      align(center + horizon, text(weight: "bold", fill: seamc.darken(35%), str(n))),
    ),
    [
      #text(weight: "bold", size: 11pt)[#title]
      #v(2pt, weak: true)
      #body
    ],
  )
]

// ── roadmap stage ────────────────────────────────────────────────────────
#let stage(id, title, body) = block(
  width: 100%,
  inset: (x: 10pt, y: 8pt),
  radius: 3pt,
  stroke: (left: 2.5pt + accent2, rest: 0.4pt + tint(accent2, 55%)),
  fill: tint(accent2, 96%),
  below: 1em,
)[
  #text(weight: "bold", fill: accent2.darken(35%))[#id] #h(4pt) #text(weight: "bold")[#title]
  #v(3pt, weak: true)
  #body
]

// ── glossary ─────────────────────────────────────────────────────────────
#let defn(t, body) = block(below: 0.7em)[
  #text(weight: "bold", fill: accent2.darken(30%))[#t] — #body
]
#let term(t) = text(fill: accent2.darken(25%), weight: "semibold")[#t]

// ── code helpers ─────────────────────────────────────────────────────────
#let bl(code)  = raw(code.text, lang: "clojure", block: true)
#let st(code)  = raw(code.text, lang: "spacetime", block: true)
#let edn(code) = raw(code.text, lang: "edn", block: true)
