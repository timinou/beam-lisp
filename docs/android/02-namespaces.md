# The android namespaces

Everything on the phone, as beam-lisp. Each namespace's own docstring is the
full story; this page is the map.

## android.app — the app

```clojure
(ns people.app (:require [android.app :as app] [people.home]))
(defn navigation [_platform] (app/stack :home 'people.home))
(defn on-start [] (app/start-root! 'people.home))
```

`stack`, `start-root!`, `push`, `pop`, `assign`, `assigns`, `platform` (`:android`, or
`:host` on the desk), `dist!`, `module` (a namespace → the BEAM module mob is
given). `start!` is what the phone runs at boot.

## android.screen — what makes a namespace a screen

```clojure
(ns people.home (:require [android.screen :refer [defscreen ok noreply]]
                          [android.app :as app] [android.ui :as ui]))
(defscreen)
(defn mount [_params _session socket] (ok (app/assign socket :n 0)))
(defn render [a] (ui/text (str "taps: " (:n a))))
(defn handle_info [msg socket] (noreply socket))
```

`(defscreen)` defines the ten callbacks mob calls; define yours after it.
Their names keep mob's underscores because mob calls them by name.
`(defscreen {:vsn 1 :persist? true})` keeps assigns across restarts.

## android.ui — screens as data

```clojure
(ui/column {:padding 24 :gap 12 :background :paper}
  (ui/text "Rita wrote" {:size :xl :color :ink})
  (ui/button "Call back" [(erlang/self) :call] {:background :forest}))
```

`column` `row` `box` `scroll` `text` `button` `spacer` `divider` `card`, and
`el` for any other mob element. Props are kebab keywords (`:text-size`); short
names `:color` `:size` `:weight` `:align` work too. Colours are palette names
(`:ink`, `:paper`, `:forest`, `:people`…), `"#RRGGBB"`, or `[r g b]`. A tap
handler is `[pid tag]`; the screen receives `{:tap tag}` in `handle_info`.

## android.events — everything the phone says

```clojure
(events/subscribe! :notify)                      ; or :notify/posted, :all
(receive [:android :notify/posted n] (get n "title"))
(events/await-event :overlay/tap 3000)
(events/recent 5)                                 ; the last events, oldest first
(events/emit! :notify/posted {"title" "test"})   ; simulate one
```

Topics: `:notify/posted` `:notify/removed` `:notify/action` `:notify/connected`
`:reader/event` `:overlay/tap` `:overlay/shown` `:overlay/hidden` `:proxy`.
Payloads are maps with string keys.

## android.jvm — every Android API

```clojure
(jvm/new "android.app.NotificationChannel" "people" "People" 4)
(jvm/call nm :create-notification-channel ch)     ; kebab → camelCase
(jvm/static "android.provider.Settings$Secure" :get-string resolver "x")
(jvm/field "android.os.Build$VERSION" "SDK_INT")
(jvm/service "notification")                      ; getSystemService
(jvm/describe "android.app.Notification$Builder") ; what a class offers
```

Handles look like `{"$h" 7, "class" "…"}`. Numbers, strings, booleans, lists
and maps cross by value; `(jvm/float 1.5)` `(jvm/long 3)` `(jvm/enum cls v)`
`(jvm/klass cls)` say what JSON cannot. `call-ui` runs on the main thread.
`proxy` implements a Java interface whose calls arrive as `:proxy` events.
`release` lets the JVM forget handles. A Java exception is a beam-lisp
exception whose `ex-data` carries `:android/error`.

## android.notify — notifications, both ways

Posting:

```clojure
(notify/channel! {:id "people" :name "People" :importance :high})
(notify/post! {:id 7 :channel "people" :title "Rita wrote" :text "are you coming?"
               :style {:messaging {:self "me" :messages [{:from "Rita" :text "are you coming?"}]}}
               :actions [{:id :open :title "Open"} {:id :reply :title "Reply" :reply? true}]})
```

Taps and replies arrive as `:notify/action` events. Also: `cancel!`
`cancel-all!` `posted` `channels` `delete-channel!` `permitted?`
`request-permission!`.

Listening to every app (after `bl android grant listener`):

```clojure
(notify/active)                 ; every notification on the shade, as maps
(notify/act! key 0)             ; fire action 0
(notify/reply! key "on my way") ; inline reply
(notify/open! key) (notify/dismiss! key)
```

## android.loom — a loom page as a screen

```clojure
(ns people.board
  (:require [android.loom :refer [defloom]] [android.events :as events] [loom.ui :as ui]))

(defn view [n] (ui/button {:on-click [:inc]} (str "taps: " n)))
(defn on-event [n ev] (if (= ev [:inc]) (+ n 1) n))
(defn init [_params] (events/subscribe! [:notify]) 0)

(defloom {:title "Board" :init init :view view :on-event on-event})
```

`defloom` goes after the fns it names. Every message the screen receives folds
through `on-event`: a tap arrives as the term the view wrote (`[:inc]`), an
`android.events` delivery as itself (`[:android :notify/posted n]`). An input
with `:on-keydown.enter [:answer k]` sends `[[:answer k] "the text"]`.

```clojure
(android.loom/js "document.title")   ; the live page, as data; throws on a page error
(android.loom/state)                  ; the state of the loom screen in front
(android.loom/emit! [:inc])           ; fold an event from anywhere
(android.app/push socket 'people.board)  ; open it from another screen
```

A link the page follows opens outside the app. A page recreated under the
screen gets the current frame, not the first.

## android.reader — read any screen

After `bl android grant reader`:

```clojure
(reader/texts)            ; [{:text "Network & internet" :bounds [l t r b]} …]
(reader/screen-text)      ; the same, one line per text
(reader/tree 6)           ; the window's node tree, to depth 6
(reader/foreground)       ; "com.android.settings"
(reader/find "Wi")        ; nodes whose text contains it
(reader/click! "Network & internet")   ; web pages too: a DOM node is tapped
(reader/tap! 540 1200)    ; a finger at x, y (pixels), over any app
(reader/global! :back)    ; :home :recents :notifications
(reader/stream! true)     ; window changes and clicks as :reader/event
```

## android.overlay — draw over any screen

After `bl android grant overlay`:

```clojure
(overlay/show! {:id :nudge :kicker "PEOPLE" :title "Call Rita back"
                :body "She wrote twice." :gravity :top :y 64})
(overlay/shown)           ; [:nudge]
(overlay/hide! :nudge)  (overlay/hide-all!)
```

A tap on a card arrives as `[:android :overlay/tap {"id" "nudge"}]`. Keys:
`:kicker` `:title` `:body` `:gravity` `:y` `:bg` `:fg` `:border` `:radius`
`:width` `:touchable`. Android hides third-party overlays over its own
Settings screens; everywhere else they float.
