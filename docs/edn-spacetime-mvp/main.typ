#import "_preamble.typ": *
#show: conf

// ── title ────────────────────────────────────────────────────────────────
#v(4em)
#align(center)[
  #text(size: 26pt, weight: "bold")[The Spell Duet]
  #v(0.6em)
  #text(size: 14pt, fill: accent.darken(20%))[EDN owns the session. Spacetime owns the surface.]
  #v(1.2em)
  #text(size: 11pt, fill: mutec)[
    MVP spec — replacing the beam-lisp Clay view layer with a live Spacetime environment \
    driven through `spacetime live`, a sidecar-grade evolution of `spacetime mcp`.
  ]
  #v(2em)
  #text(size: 9.5pt, fill: mutec)[ora · 2026-08-11 · draft for settlement]
]
#v(3em)

#align(center)[
  #grid(
    columns: (1fr, auto, 1fr),
    gutter: 12pt,
    align: horizon,
    box(fill: tint(accent, 90%), radius: 4pt, inset: 10pt, width: 100%)[
      #text(weight: "bold", fill: accent.darken(35%), size: 9pt)[EDN / beam-lisp]
      #v(2pt)
      #text(size: 8.5pt)[views · signals · intents \
        templates · basic macros \
        mission ontology · state \
        the *what*]
    ],
    text(size: 16pt, fill: seamc)[⇄],
    box(fill: tint(accent2, 90%), radius: 4pt, inset: 10pt, width: 100%)[
      #text(weight: "bold", fill: accent2.darken(35%), size: 9pt)[Spacetime]
      #v(2pt)
      #text(size: 8.5pt)[layout · design language \
        animation · styling \
        shell-local signals \
        the *how it looks and moves*]
    ],
  )
]

#pagebreak()
#outline(title: [Contents], indent: 1.5em)
#pagebreak()

// ── parts ────────────────────────────────────────────────────────────────
#include "parts/01-purpose.typ"
#include "parts/02-context.typ"
#include "parts/03-spacetime-improvements.typ"
#include "parts/04-architecture.typ"
#include "parts/05-edn-language.typ"
#include "parts/06-mvp-experience.typ"
#include "parts/07-modules.typ"
#include "parts/08-self-evolution.typ"
#include "parts/09-roadmap.typ"
