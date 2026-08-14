#import "../_preamble.typ": *

= The EDN side: session ontology and views

== The ontology

Everything on screen is a projection of one EDN value, the #term[session],
held in `spell.store` under `:session`. Its schema (versioned, fingerprinted
like a bridge contract):

#edn(```
{:schema :spell.session/v1
 :mission {:id "m-01"
           :title "…"
           :body {:markdown "…long-form mission statement…"}
           :created-at 1783000000}
 :follow-ups [{:id "f-01" :body {:markdown "…"} :at …}
              {:id "f-02" :body {:markdown "…"} :at …}]
 :turns [{:id "t-01"
          :trigger {:kind :mission :ref "m-01"}     ; or {:kind :follow-up :ref "f-01"}
          :status :done                              ; :running | :done | :failed
          :kind :investigation                       ; or :implementation
          :output {:format :markdown :body "…"}     ; or {:format :forms …} below
          :log [{:at … :kind :tool :summary "…"}     ; deep log entries
                {:at … :kind :gate :verdict :ok :detail "…"}
                {:at … :kind :action :signal "$approve" :payload …}]}]
 :wiring […]                                          ; §5.4
 :intents #{"spell.ops/refine" …}}                    ; fast-follow registry
```)

Ontology rules (enforced by `spell.session`, not by convention):

+ A session has exactly one mission; follow-ups only ever append to
  `:follow-ups`. The attachment timeline is the vector order — nothing else
  may reorder it.
+ A turn is created by a trigger (mission or follow-up), transitions
  `:running → :done | :failed` exactly once, and is immutable thereafter.
  The turn's `:output` is the big end-of-turn artifact.
+ The log is append-only. UI collapse state is a shell signal, never session
  data.

== The shell: one Spacetime function

The entire interface is one mounted function, `spell/shell`, written in the
Spacetime design language. Its input is a projection of the session value;
its internals are pure presentation. Sketch:

#st(```
@fn shell(session Session) {
  @mcp-input session

  @data inline $open-turn string : "" ;      // shell-local: which turn is expanded
  @data inline $log-open  bool   : false ;

  .mission {
    > .title   { text: $.session.mission.title }
    > .body    { markdown: $.session.mission.body }   // IMP-N3 markdown slot
  }

  .timeline {                                 // follow-ups: the attachment timeline
    @each $f in $.session.follow-ups {
      > .follow-up { markdown: $f.body }
    }
  }

  .turns {
    @each $t in $.session.turns {
      > .turn {
        @on click { $open-turn <- $t.id }
        > .output.hero { markdown: $t.output.body }   // big, end-of-turn artifact
        > .log {
          @when $log-open {
            > stream-log { source: session-events }    // IMP-N4 log stream
          }
        }
      }
    }
  }

  .composer { @mcp-submit $follow-up(fields: [body]) : to agent+log }
}

// ↓ everything below this line is the design language's affair:
//   tokens, type scale, warm-dark palette, entry animations, @flip on
//   timeline append, scroll-spy on the log, … EDN never sees it.
```)

The EDN side contains #emph[no layout]. It can name slots (`mission.body`,
`turn.output`) and reference signals (`$open-turn`); it cannot express a
margin. Conversely the `.st` side contains no session semantics: it renders
whatever projection it is fed.

== Turn outputs: markdown and forms

A turn output is either markdown (rendered big, the "hero") or a form
collection — the agent's way to ask rather than tell:

#edn(```
{:format :forms
 :forms [{:id "choose-direction"
          :kind :picker                 ; kit function, not new machinery
          :title "Two ways to cut this"
          :options [{:id :a :label "EDN-driven slots" :pros "…" :cons "…"}
                    {:id :b :label "Full .st generation" :pros "…" :cons "…"}]
          :action {:signal "$choose" :to :agent}}
         {:id "confirm-apply"
          :kind :confirm
          :title "Apply the refactor?"
          :action {:signal "$apply" :to :agent}}]}
```)

`spell.view` compiles each form entry to a kit mount (`picker.st`,
`confirm.st`, `form.st`) with the payload as `@mcp-input`. The kit's async
buttons already do the right thing; IMP-N2's `:to` field routes the result.
Because the forms live inside the turn's output region, the user experiences
them #emph[in place], under the output, not in a modal elsewhere.

#note[
  MVP vs fast-follow, precisely: in the MVP the agent #emph[declares] forms
  in its output and the beam-lisp process mounts them on the user's next
  view — submission returns via notification/`st_await` on the agent's next
  turn boundary. Fast-follow (§9) makes the round-trip intra-turn: the agent
  emits a form, blocks on `st_await`, and continues in the same turn. The
  mechanism is identical; only the agent's waiting posture changes.
]

== The load gate: fail at environment load, not at click time

The duet's central consistency rule. When a session boots (and whenever the
shell or wiring is re-`st_fn_put`), `spell.gate` checks, against the
sidecar's self-describing registry (IMP-A1):

+ every `$signal` named in EDN (`:action {:signal "$choose" …}`, stream
  sources, slot bindings) exists in the compiled shell/kit signal registry;
+ every slot named in EDN (`mission.body`, `turn.output`) exists in the
  shell's `@mcp-input` projection type;
+ every `:to :intent` destination names a registered intent in `:intents`;
+ the shell's contract fingerprint matches the one the session was last
  gated against — drift is a loud re-gate, not silent skew.

Verdicts are data, appended to the log (`:kind :gate`), and a failing gate
leaves the session #emph[parked]: the shell renders the last-good state with
a gate banner, and nothing new mounts. This is the EDN-side analogue of the
bridge's contract checker (§2.3) and of E0928 handler validation: the seam
is proven before it is used.

#risk[
  The gate is only as strong as the registry is complete. If IMP-A1's
  introspection omits shell-local inline signals, the gate must treat them as
  a distinct visibility class (EDN may never reference them) rather than
  silently allowing dangling names.
]
