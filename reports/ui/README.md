# `reports/ui` — the faces, verified in a browser

`ui.typ` is the report. `shots/` holds the screenshots it includes, and every one
of them was taken from a real listener with a real browser drive — no mocks, no
hand-written HTML in a file.

## Build

```sh
typst compile reports/ui/ui.typ reports/ui/ui.pdf      # the report
typst watch   reports/ui/ui.typ reports/ui/ui.pdf      # while editing
```

## Reproduce what the report claims

```sh
# the pane's numbers, from the terminal
./bin/bl daemon status

# the hotel page
./bin/bl serve examples/hotel/desk.bl &
curl -s -i localhost:4048/ | head -40
curl -s 'localhost:4048/?server=housekeeping&id=audit&op=pause' | grep -o 'paused' | head -1
pkill -f desk.bl
```

The screenshots come from the harness's browser at a 1440×900 viewport, so a
figure in `ui.typ` corresponds to a state you can reach with the commands above.

## Why this folder exists at all

A UI change is the easiest kind to believe without evidence: the code "looks
right", the HTML string "obviously" renders. This repo has already paid for that
belief twice in one session — a page that returned an empty 200 (the route
matched, the render raised) and a page whose stylesheet call took a tree where it
wanted a thunk. Both looked fine in the source.

So: a face is verified when someone has *loaded it, read it, clicked it, and seen
the fact move where the fact lives* — and that is what this folder records.
