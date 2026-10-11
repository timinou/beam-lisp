# Make a demo from a scenario

Write a demo alongside its end-to-end assertions in one `.bl`, `.bl.org` or
`.bl.md` source. One file can declare several independent demo tests and share
ordinary functions for setup. `scenario.demo/defdemo` registers each with the
existing test engine; `scene` annotates ordinary scenario events with their
client presentation.

```clojure
(ns project.demos
  (:require [scenario :as s] [scenario.demo :as demo]
            [browser.film :as browser] [browser.page :as page]))

(defn options []
  {:world (fn [{:keys [frames]}]
            (browser/owned-world :viewer (browser-options) frames))
   :film {:voice "aura-2-hector-fr" :language "fr"}
   :export {:env-file ".env"}})

(demo/defdemo save-a-document (options)
  (s/scenario "Enregistrer un document" {:viewer {}}
    [(s/does :viewer [:navigate "http://127.0.0.1:4000/"])
     (s/does :viewer [:wait "!!document.querySelector('#save')"])
     (demo/scene :save
       {:title "Enregistrer votre document"
        :say "Enregistrez votre document. Votre travail est conservé."
        :camera [{:at 0 :zoom 1} {:at 2 :zoom 1.4 :x 0.8 :y 0.7}]}
       (s/does :viewer [:click "#save"])
       (s/sees :viewer (fn [p _] (= "Enregistré" (page/evaluate! p "document.querySelector('#status').textContent")))
         "The saved document is confirmed"))]))

(demo/run-tests! "project.demos")
```

`browser-options` supplies your browser runtime and viewport; `owned-world`
defaults to short temporary profile/runtime directories and cleans them up.
Explicit paths remain available for caller-managed persistent profiles.
The executable [two-demo literate example](../../examples/scenario/browser-demos.bl.org)
includes that setup. Importing or declaring a demo starts no browser or speech
request. Use `bl -p optional/browser-port/bl test project/demos.bl.org` for
ordinary tests with captured evidence. `BL_DEMO_EXPORT=1` also renders one
movie per demo. `bl run` executes the same tests through `demo/run-tests!`;
inside the test command that call leaves execution to the normal test driver.

Scenes keep scenario semantics: the same events, witnesses, patterns and
assertions run through `scenario/run-world`. Scene names are unique within a
demo. Events outside scenes are asserted setup. Scenes select captured frames
and real clicks automatically, with an initial before-state when available.
`:step-seconds` controls their presentation spacing (default 0.6 seconds).
`:capture :end` holds the final observed state. `:cursor []` hides the pointer;
an explicit keyframe vector overrides its captured track. The camera, subtitle,
local audio and other film options below also work inline. Visual tracks and
step marks extend a scene's minimum duration; speech can extend it further.

The world may be an ordinary map or `(fn [context] world)`, with context
`{:id :output :frames}`. A custom world supplies captured image paths through
its `:basis :frame`, or a scene supplies `:source`/`:shots`. The optional native
`browser/owned-world` acquires its page when execution starts. Its `:dispose!`
hook is called in `finally`, including after an action exception. The existing
caller-owned `browser/world` remains available. `:with-fixture (fn [run] …)`
wraps execution with a project's fixture setup and cleanup.

Outputs default to `!tasks/evidence/demos/<namespace>/<test-name>/`; `:output`
overrides the directory. `run.edn`/`run.json` retain normalized observations,
with executable predicates represented by markers and their actual verdicts
preserved. The library derives `film.json`, measured presentation marks and
`suite.edn`; these are generated artifacts. `demo/run!` returns their values
for ordinary `deftest` integration, while `defdemo` reports each claim through
the existing assertion reporter. Refuted or unverified runs remain available
for inspection and cannot produce a client export.

`demo/serve!` opens all generated demo tests below a directory in the standard
runner, with screenshots, movies and captions on one loopback origin:

```clojure
(def gallery (demo/serve! "!tasks/evidence/demos/project.demos" {:port 4163}))
;; Later:
(demo/stop! gallery)
```

It resolves artifact URLs when opening the gallery and serves only registered
media files, with byte-range seeking. Each exported step's film time comes
from its scene; no separate registration script or hand-maintained frame map
is needed.

## Direct film authoring

`scenario.film` authors a film as data. Keep the scenario's assertions in its
run; write the film's narration for the people watching it.

```clojure
(require '[scenario.film :as film])
(def demo
  (film/from-run run
    [{:id "review" :source "/absolute/evidence/review.png"
      :title "Comparer la source et le document"
      :say "Repérez le montant qui demande votre attention."
      :camera [{:at 0 :zoom 1 :x 0.5 :y 0.5}
               {:at 2 :zoom 1.4 :x 0.8 :y 0.4}]
      :cursor [{:at 0 :x 0.5 :y 0.5}
               {:at 1 :x 0.8 :y 0.4 :click true}]}]
    {:title "Relire un document" :voice "aura-2-hector-fr" :language "fr"}))
(film/export! demo "/absolute/demo" {:env-file "/private/project/.env"})
```

The optional worker needs Python 3, FFmpeg/ffprobe with libx264, libass and
drawtext, plus `rsvg-convert` for pointer graphics. Importing the namespace
starts no browser or provider. For a source checkout loaded into another
runtime, pass `:worker "/checkout/priv/lib/scenario/film/render.py"`.

Deepgram credentials come from `DEEPGRAM_API_KEY` at export time. An optional
dotenv file supplies missing environment values; it is parsed as data. Keep
that file ignored by Git. The film value and manifest carry the voice name,
text and media hashes, never the key. Speech files are cached by model, text
and sample rate inside the export directory. A local `:audio` path gives an
offline export with the same measured timing rules.

Each scene accepts a local image or video `:source`, `:source_start` in seconds,
and `:speed` from 0.1 to 8. Video keeps its recorded motion and freezes its last
frame when the narration needs longer. Original source audio is replaced by
the authored narration. Scene `:duration` is a minimum. The exporter measures
speech, adds `:lead` (default 0.35 seconds) and `:tail` (default 0.55, minimum
0.25), then rounds the scene up to a video frame. Every complete subtitle cue
covers the complete speech interval and reading tail. Keep each passage short
enough for two subtitle lines. `:subtitle` can spell out an abbreviation or
display a number differently from `:say`.

A scene can instead carry `:shots [{:at 0 :source "before.png"}
{:at 1.8 :source "after.png"}]`. These held state captures must share viewport
dimensions. Times start at zero and increase within the measured scene. Use
the last real click coordinates from the capture to author a cursor gesture;
change to the observed result screen just after that click. Each shot's source
hash is retained separately in the manifest.

Camera and cursor coordinates are normalized to the original source image:
`0,0` is its top left; `1,1` its bottom right. `:at` is local scene time. Camera
keys accept zoom 1–4 and a center `:x/:y`; the crop stays inside the contained
frame. Cursor keys accept `:x/:y` and optional `:click true`. Both tracks ease
between keys and hold their endpoint values. Narration and chapter labels have
reserved bands outside the source image. `:background`, `:title` and `:label`
set the film's presentation; `:width/:height/:fps` set encoding dimensions.

The export directory contains `demo.mp4` with burned captions and a selectable
subtitle track, `subtitles.srt`, `subtitles.vtt`, `chapters.ffmetadata`, the
authored `film.json`, cached speech, intermediate clips and `manifest.json`.
The manifest records source and audio SHA-256 hashes, measured speech intervals,
subtitle intervals, final movie hash, and the original run's verdicts. A film
is an edited presentation; its cursor gestures and camera are editorial
annotations. The referenced scenario remains the authority for behavior.

Scenario Runner plays a run's `:media {:src … :captions … :language …}` in its
program monitor. Each step's `:t` is its position in that media. Clicking a
timeline step seeks the existing player; its play button and space bar control
video playback. A film starts at its first step. A run without media keeps the
state/screenshot monitor. Keep a separate original run when attaching an edited
film clock. Cross-origin media with a caption track needs CORS response headers
from its media server.

For local evidence, `scenario.film.http/serve-file` accepts a caller-authorized
path and MIME type and serves it through Plug's file transport. It supports
browser byte-range seeking, suffix requests, HEAD and unsatisfiable-range 416
responses. Keep path authorization and CORS in the host. Movies can then seek
without copying the complete file into the BEAM heap for every request.

For an existing JSON edit, run the same worker directly:

```sh
python3 priv/lib/scenario/film/render.py film.json --out /tmp/demo --env-file .env
python3 test/bl/scenario/film_render_test.py
./bin/bl test test/bl/scenario/film_test.bl
```
