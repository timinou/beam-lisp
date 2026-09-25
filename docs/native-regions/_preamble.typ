// A small adapter over the repository's existing greyscale document theme.
#import "../typing/_preamble.typ" as theme

#let guide(title: none, subtitle: none, body) = theme.typing-doc(
  title: title,
  subtitle: subtitle,
  kicker: "BEAM Lisp · A field guide",
  sans-font: ("Inter", "DejaVu Sans"),
  justify: false,
  leading: 0.55em,
  paragraph-spacing: 0.9em,
  body,
)

#let idea = theme.idea
#let decision = theme.decision
#let contrast = theme.contrast
#let term = theme.term

// A recipe is a design technique, not a claim that every compiler pass exists.
#let recipe(body) = theme.idea(title: "Design recipe", body)
#let exercise(body) = block(breakable: false, theme.idea(title: "Try it", body))
