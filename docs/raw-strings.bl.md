# Raw strings — text that must contain text

> This is a **literate program**. Every `beam-lisp` block below runs:
> `bl run docs/raw-strings.bl.md`. The prose is the narrative; the code is the proof.

Every string literal in beam-lisp used to be `"…"`, so any text holding a quote
has to escape it — and an escaped quote is exactly what a tool that re-escapes
its input mangles **twice**. The tree's own journal records the case: a `.bl`
file carrying inline CSS and JS, quotes doubled on the way to disk, the file
that came back not the file anyone wrote.

`#|…|` is the way out. A **raw** body interprets nothing.

```beam-lisp
(def css #|.card { content: "★"; }|)

(println css)
(println "bytes:" (count css))
```

No `\"`, no `\\`, no `\n`: the quote is a quote, the backslash is a backslash,
and the star is one character, not three bytes.

## The opener's pipe count is the closer's

`#|` ends at the first `|`, `#||` at the first `||`, `#|||` at the first `|||`.
A run of a DIFFERENT length is body text — which is exactly what lets a body
carry the delimiter it did not spend.

```beam-lisp
(println #||a | b||)      ; one pipe inside a two-pipe body
(println #|||a || b|||)   ; two pipes inside a three-pipe body
```

## A newline is a newline; nothing is trimmed

The body is verbatim: leading and trailing whitespace, indentation and tabs all
survive, exactly as they do inside `"…"`.

```beam-lisp
(def banner #|
  first  "quoted"
	tabbed
last|)

(println banner)
(println "lines:" (- (count (String/split banner "\n")) 1) "bytes:" (count banner))
```

## A tag can take a raw body

`#tag|…|` reads as `(your-reader-fn "body")`, the same shape `#time"…"` has —
so a tag can parse markup, a query, a template, or nothing at all (the demo
below hands the text straight back).

Registration is **read-time**: a tag must already exist when the unit that uses
it is *read*, which for a namespace means an earlier entry in the same
`:require` list, and for the language's own tags means the boot registry
(`priv/boot/data-readers.bl`, where `#d` and `#time` live). This document is one
unit, so it exercises the tagged form the honest way — the source is built as a
string and read:

```beam-lisp
(defn hand-back [s] s)
(data-reader! "raw" (quote hand-back))

(def source (str "#raw|a " "\"" "b" "\"" " c|"))
(println source)

; `read_all` answers the BARE shapes: the literal became a call to the
; registered reader fn, with the body as its only argument.
(def form (first (BeamLisp.Reader/read_all source)))
(def items (second form))                 ; the (fn …) items
(println "reads as:" (pr-str form))
(println "the fn:" (pr-str (first items)) "the body:" (pr-str (second items)))
```

## The lint knows the old spelling

A file that predates this form says `"he said \"hi\""`. `bl lint --tier
every` names each of those, and `bl fix --tier every` rewrites them. The rule is
`escaped-quotes→raw-string`, and it lives in the opt-in tier for a measured
reason: in this tree it fires on 611 literals in 113 files, so as a default it
would drown the report and rewrite the codebase at once. Naming the tier is the
opt-in.

It reads the SOURCE, not the tree of forms. A literal is one of the shapes the
reader does not wrap — no span to slice, and `pr-str` of a binary drops its
quotes — so this rule answers in text offsets instead of a pattern. It fires
only where the raw spelling is strictly better: the value holds a quote (there
is escaping to remove), holds no `|` (that would close the body early), and
uses no escape that STANDS FOR a character (`\n`, `\t`) — writing those out
literally would re-flow the file, which is a layout decision no spelling rule
gets to make.

```beam-lisp
(def src "(def msg \"he said \\\"hi\\\"\")\n(def kept \"a\\nb\")\n")
(def fixed (:source (deodorant/fix-source-preserving
                      (deodorant/rules-of-tier :migration) src)))

(println fixed)
(println "same forms?"
         (= (BeamLisp.Reader/read_all src) (BeamLisp.Reader/read_all fixed)))
```

The `\n` literal stays put, the escaped quote does not, and both sides READ the
same form — the guarantee that matters for a change of spelling.

A sweep that reaches `priv/boot/` is a boot-tier change: the floor is compiled
from those bytes, so it ends with `bl build && bl seed --ebin build`.

## When not to reach for it

If the text is a document in its own right — a stylesheet, a query, a
template — keep it in a file and read it. A raw literal is for text that
*belongs in the source*; a file gets syntax highlighting, a diff, and no
reader rules at all.

```beam-lisp
(println "LICENSE starts:" (subs (File/read! "LICENSE") 0 14))
```

## What it is not

Clojure does not have this form (Racket's `#<<EOS` here-string is the outlier
among Lisps), so a `.cljc` file that uses it is beam-lisp-only. The extension is
**additive**: `#|…|` is a *read error* in Clojure, so a program that reads on
the JVM cannot mean something different on the BEAM.
