#import "../_preamble.typ": *

= Self-evolution through introspection

Part of the infrastructure — not the MVP core — is that the duet can inspect
and rewrite itself. The instinct (optics / Specter hooks) is right, and this
section states precisely where each tool belongs, because they operate at
different levels.

== The three levels of "self"

+ #strong[Session value] — plain EDN data in `spell.store`. Transformed
  constantly (every turn, every follow-up).
+ #strong[View terms] — the wiring table, form specs, and projections that
  `spell.view` compiles. EDN data #emph[about] the interface.
+ #strong[Sources] — `.bl` namespace forms and `.st` shell source. Changed
  rarely, dangerously, and only through `spell.self` (compile → load →
  fence-verify → revert-on-failure) on the beam-lisp side and gated
  `st_fn_put` on the Spacetime side.

== Where optics and Specter fit

#module("optics (`priv/optics.bl`)", "VALUE TRANSFORMS",
  owns: [composable paths (`in`, `idx`, `traversed`, `filtered`, `optional`)
         and focused rewrites (`view`, `over`, `setv`)],
  disowns: [selection predicates, short-circuiting])[
  Level 1 workhorse. Session mutations are optic transforms:
]

#bl(```
;; append a follow-up — one focused rewrite of one path
(optics/over (optics/in :follow-ups)
             (fn [fs] (conj fs follow-up))
             session)

;; close every running turn whose trigger was this follow-up
(optics/over (optics/*> (optics/in :turns) optics/traversed)
             (fn [t] (if (and (= :running (:status t))
                              (= fup-id (get-in t [:trigger :ref])))
                       (assoc t :status :failed)
                       t))
             session)
```)

#module("specter (`priv/specter/`)", "TERM SURGERY",
  owns: [`ALL`, `keypath*`, `must*`, `pred*`, `srange*`; select /
         select-first / transform / setval over nested EDN terms],
  disowns: [code installation])[
  Level 2 workhorse — this is where "register hooks" becomes concrete. A
  #term[hook] is a Specter path plus a transform, registered in the session's
  wiring table and re-checked by the gate:
]

#bl(```
;; hook: every form action routed :to :agent also logs — registered as a
;; wiring transform, applied by spell.view at compile time
(specter/transform
  [:forms specter/ALL :action (specter/pred* #(= :agent (:to %)))]
  (fn [a] (assoc a :also :log))
  output-term)

;; introspection: which signals does this output reference?
(specter/select
  [:forms specter/ALL :action :signal]
  output-term)   ;; → ("$choose" "$apply") — fed to spell.gate
```)

The second example is the important one: Specter is how the gate #emph[finds]
the cross-references it must prove. Hooks are data (path + predicate +
transform), so they are enumerable, gateable, and revertible — which
free-form code hooks would not be.

== What neither library does

Neither optics nor Specter touches Level 3: no source introspection, no
namespace-form enumeration, no binary installation. That remains
`spell.self`'s contract, blocked on the bounded data reader and
compile-string→binary. The duet does not unblock it; it gives it a safer
target: evolving the #emph[wiring] and #emph[gate rules] (data, Levels 1–2)
covers most of what self-evolution wants day-to-day, and Level 3 stays rare
and fenced.

#openq[
  Should hooks live in the session value (evolvable at runtime, gated) or in
  `.bl` source (static, reviewed)? This spec puts them in the session value
  and leans on the gate + log for accountability. If hook behaviour ever
  needs hot-code properties (closures over evolving code), promote specific
  hooks to named intents and let `spell.self` own them.
]
