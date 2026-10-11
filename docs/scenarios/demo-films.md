# Make a demo from a scenario

`scenario.film` authors a film as data. Keep the scenario's assertions in its
run; write the film's narration for the people watching it.

```clojure
(require '[scenario.film :as film])
(def demo
  (film/from-run run
    [{:id "review" :source "/absolute/evidence/review.png"
      :title "Compare the source and the document"
      :say "Find the amount that needs your attention."
      :camera [{:at 0 :zoom 1 :x 0.5 :y 0.5}
               {:at 2 :zoom 1.4 :x 0.8 :y 0.4}]
      :cursor [{:at 0 :x 0.5 :y 0.5}
               {:at 1 :x 0.8 :y 0.4 :click true}]}]
    {:title "Review a document" :voice "aura-2-hector-fr" :language "fr"}))
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

For an existing JSON edit, run the same worker directly:

```sh
python3 priv/lib/scenario/film/render.py film.json --out /tmp/demo --env-file .env
python3 test/bl/scenario/film_render_test.py
./bin/bl test test/bl/scenario/film_test.bl
```
