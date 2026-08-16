# spell/study — verified experiments that are not the application

Four namespaces live here. None of them is loaded by `spell.app`, none is
reachable from the chat loop, and that is deliberate rather than an oversight:
each one answered a question, the answer was recorded, and the code is kept
because it is *evidence* — not because anything calls it.

    main.bl        the harness study's entry point
    spell/ui.bl    VIEW    — a UI tree as pure data, grapheme-exact editing
    spell/st.bl    an atom→browser connector built on `add-watch`
    spell/clay.bl  a written protocol contract (a stub, deliberately)

Run the study:

    mix beam_lisp.run --path spell/study --path spell/src spell/study/main.bl

(Both paths: the study uses `spell.fence` and `spell.store`, which are still in
`spell/src` because the application's provider layer documents its debt to
them.)

## Why they are not deleted

`spell.ui` is the one cluster of the jank port that was fully verified — a UI
tree that is ordinary data, with editing operations that are grapheme-exact
where the original counted codepoints. `PLAN-017` records that finding, and
`spell/README.md` still cites this code as the evidence for it. Deleting
verified study material to tidy a directory listing trades a permanent record
for a cosmetic gain.

`spell.clay` is a protocol contract written down before an implementation
exists. That is a legitimate artefact: the next person to build the client
starts from a specification rather than from a guess.

## Why `spell.st` is here rather than in `spell/src`

This is the one that needed a decision, and it is worth stating plainly.

`spell.st` is a **second answer to a question the application already
answers**: how does server state reach the browser? Its answer is an
`add-watch` on an atom that diffs declared keys and pushes what changed —
elegant, and genuinely the thing `add-watch` was added to the runtime for.

The application's answer is the contract/seam design: a term declares assigns,
`spell.server` walks handler bodies, and the LiveView bridge pushes the diff.

Two answers to one question is exactly what `PLAN-027` exists to remove. But
`spell.st` is not a *duplicate implementation inside the application* — nothing
in `spell.app` requires it, and no code path can reach both. It is a road not
taken, with a working demonstration attached.

So: moved, not deleted. Here it is clearly an experiment. In `spell/src` beside
`spell.server` it was an invitation to build on the wrong one — someone reading
that directory could reasonably conclude either was current.

`test/beam_lisp/watches_test.exs` still exercises it, because the runtime
primitive it rests on (`add-watch` / `remove-watch`) IS application code and
its tests should not evaporate with the experiment that motivated it.
