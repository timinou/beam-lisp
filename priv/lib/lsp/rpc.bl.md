# lsp.rpc — the language server's protocol layer, as pure functions

`lsp.bl` answers questions about a program: hover, definitions, references,
document symbols, live diagnostics, and the proof-backed queries no standard
LSP request names. Every one of those answers is a function of source text.
Nothing there knows about JSON, pipes, or line endings. This namespace is the
wire.

An editor speaks JSON-RPC 2.0 over a byte stream. Each message is a header
block carrying `Content-Length: N`, a blank line, then exactly `N` bytes of
JSON. Two functions do all of it:

- `decode-frame` peels one message off the front of a byte buffer, answering
  `{:msg m :rest bytes}` when a whole frame is present, `{:need n}` when more
  bytes must arrive, or `{:error reason :rest bytes}` for a malformed header.
- `encode-frame` is its inverse: a message map in, `Content-Length: N\r\n\r\n`
  followed by the JSON bytes out.

The dispatch is one pure function, `handle`. Give it the server's state and one
inbound message; get back the next state and the list of messages to send.
Nothing here touches a port, so every protocol rule is a test that runs with
maps in and maps out — which is what makes the language server testable without
an editor.

```beam-lisp
(ns lsp.rpc
  (:require [lsp]))
```

## Server state

State is a plain map: the open documents keyed by URI, the workspace root, and
two flags. A document carries its text, its client-side version, and the
namespace derived from its leading `(ns …)` form, so a request never re-derives
what a change already knows.

```beam-lisp
(defn initial-state
  "The state of a server that has not yet received `initialize`."
  []
  {:docs {}
   :root nil
   :initialized? false
   :shutdown? false
   :exit? false})

(defn- doc-of [state uri] (get-in state [:docs uri]))
```

## Framing

`Content-Length` counts bytes, not characters, so framing is a byte operation:
the header block is ASCII, its byte length is the body's offset, and the body
is sliced by byte count. `decode-frame` stops at `\r\n\r\n`, reads the length,
and only claims a message when the whole body has arrived.

```beam-lisp
(defn- header-value
  "The integer Content-Length in a raw header block, or nil."
  [head]
  (let [low (String/downcase head)
        i (index-of low "content-length:")]
    (if (nil? i)
      nil
      (let [rest (subs low (+ i 15))
            line (String/trim (first (String/split rest "\r\n")))]
        (try (String/to_integer line) (catch _e nil))))))

(defn decode-frame
  "Peel one LSP frame off the front of `bytes`.

   → {:msg map :rest bytes}  a complete frame, and the bytes after it
   → {:need n}               incomplete; `n` is the total size once known
   → {:error reason :rest b} a malformed header, with `b` past the separator"
  [bytes]
  (let [i (index-of bytes "\r\n\r\n")]
    (if (nil? i)
      {:need nil}
      (let [head (erlang/binary_part bytes 0 i)
            bstart (+ (erlang/byte_size head) 4)
            end (erlang/byte_size bytes)
            n (header-value head)]
        (cond
          (nil? n) {:error :bad-header :rest (erlang/binary_part bytes bstart (- end bstart))}
          (< end (+ bstart n)) {:need (+ bstart n)}
          :else
          (let [body (erlang/binary_part bytes bstart n)
                rest (erlang/binary_part bytes (+ bstart n) (- end (+ bstart n)))]
            {:msg (Jason/decode! body) :rest rest}))))))

(defn encode-frame
  "A message map → the bytes of one LSP frame."
  [msg]
  (let [json (Jason/encode! msg)]
    (str "Content-Length: " (erlang/byte_size json) "\r\n\r\n" json)))
```

## JSON-safe values

`handle` answers in beam-lisp data — keywords, vectors, sets, lazy sequences.
Jason encodes none of those, and a beam-lisp vector reaches it as a struct it
refuses. `json-safe` lowers a value once: keywords to strings, maps to
string-keyed maps, everything sequential to Erlang lists. Every response and
notification passes through it, so the server's writer may hand Jason whatever
`handle` returned.

```beam-lisp
(defn- key-str [k] (if (keyword? k) (name k) (str k)))

(defn json-safe
  "A beam-lisp value → the lists, string-keyed maps and scalars Jason encodes."
  [x]
  (cond
    (keyword? x) (name x)
    (map? x) (reduce (fn [out t]
                       (assoc out (key-str (get t 0)) (json-safe (get t 1))))
                     {} (to-list x))
    (vector? x) (to-list (map json-safe x))
    (list? x) (to-list (map json-safe x))
    (set? x) (to-list (map json-safe (to-list x)))
    (BeamLisp.LazySeq/lazy? x) (to-list (map json-safe (doall x)))
    :else x))
```

## Positions: 1-based codepoints ↔ 0-based UTF-16

The reader counts lines and columns from 1, and columns in codepoints. LSP
counts from 0, and its `character` counts UTF-16 code units — the width of a
JavaScript string. A line holding an emoji shifts every later column by one
unit. These two functions are the only place the conversion happens, in both
directions — and they are TOTAL. A position that lies outside the document
clamps to the nearest line that exists (`line-text`): a diagnostic position is
data from another engine, and a server that raises on it costs the editor every
answer it was asked for.

```beam-lisp
(defn- utf16-width
  "How many UTF-16 code units one codepoint occupies: 2 above the BMP, else 1."
  [cp]
  (if (> (first (String/to_charlist cp)) 65535) 2 1))

(defn- utf16-length [s]
  (reduce (fn [n cp] (+ n (utf16-width cp))) 0 (String/codepoints s)))

(defn- line-text
  "The 1-based `line` of `text` nearest an existing one, WITH that line's text
   as `[line text]`.

   A diagnostic position is data from another engine, and the engines do emit
   0: `typed/warn!` spells a warning the compiler could not place as `:line 0`,
   and `system.linear/diagnostics` defaults a body annotation's line the same
   way. `(dec 0)` indexes the line list at -1, and beam-lisp's `get` answers
   nil there rather than raising — so the raise landed one call later, in
   `String.codepoints(nil)`, inside a handler that owes the editor an answer
   (`bl lsp serve: handler raised: textDocument/didOpen: no function clause
   matching in String.codepoints/1`). Clamping keeps the promise the layers
   above already made: `diagnostic->lsp` defaults a line it does not have to 1,
   so a position that cannot exist belongs at the top of the file, not in an
   exception."
  [text line]
  (let [lines (split text "\n")
        n (count lines)
        line (cond
               (not (int? line)) 1
               (< line 1) 1
               (> line n) n
               :else line)]
    [line (get lines (dec line))]))

(defn bl->lsp
  "bl's 1-based [line col] (col = codepoints) → LSP's 0-based [line character].
   A line outside the document clamps to the nearest real one, and a column
   before the first codepoint counts 0 — an answer an editor can place, always."
  [text line col]
  (let [[line l] (line-text text line)
        prefix (take (max 0 (dec col)) (String/codepoints l))]
    {:line (dec line)
     :character (reduce (fn [n cp] (+ n (utf16-width cp))) 0 prefix)}))

(defn lsp->bl
  "LSP's 0-based [line character] → bl's 1-based [line col]. A character that
   lands mid-surrogate-pair floors to the codepoint that opens it. A client
   line the document does not have has no text to walk, so the answer is that
   line's first column — an empty result upstream, never a raise: a negative
   line is not an index off the end of the line list, and a `line` that is not
   a number at all has no `inc`."
  [text line character]
  (let [lines (split text "\n")
        line (if (and (int? line) (>= line 0)) line 0)
        l (if (< line (count lines)) (get lines line) "")
        cps (String/codepoints l)]
    (loop [cs cps, col 1, seen 0]
      (if (empty? cs)
        {:line (inc line) :col col}
        (let [w (utf16-width (first cs))]
          (if (< character (+ seen w))
            {:line (inc line) :col col}
            (recur (rest cs) (inc col) (+ seen w))))))))
```

## Finding a definition's span

`lsp/document-symbols` reports what a program defines but not where each name
sits; a Location needs an address. The definition form is `(defn NAME …)` (or
its private twin), and the name is the token after the head — a text scan finds
it, keeps this layer free of reader internals, and is exactly what the plan
specifies for go-to-definition.

```beam-lisp
(defn- token-end [s]
  (loop [i 0]
    (if (>= i (count s))
      i
      (let [c (subs s i (inc i))]
        (if (or (= c " ") (= c "\t") (= c "\n") (= c "\r")
                (= c "(") (= c ")") (= c "[") (= c "]")
                (= c "{") (= c "}") (= c ","))
          i
          (recur (inc i)))))))

(defn ns-of
  "The namespace a source declares via its leading `(ns NAME …)`, else \"user\"."
  [src]
  (let [code (filter (fn [l] (not (starts-with? (triml l) ";")))
                     (split src "\n"))
        flat (join " " code)
        i (index-of flat "(ns ")]
    (if (nil? i)
      "user"
      (let [t (triml (subs flat (+ i 4)))
            e (token-end t)]
        (if (> e 0) (subs t 0 e) "user")))))

(defn- name-boundary? [s idx]
  (or (>= idx (count s))
      (let [c (subs s idx (inc idx))]
        (or (= c " ") (= c "\t") (= c "\n") (= c "\r")
            (= c "(") (= c ")") (= c "[") (= c "]")
            (= c "{") (= c "}") (= c ",")))))

(defn find-defn
  "The 1-based [line col] of the `NAME` in a top-level `(defn NAME …)` (or
   `defn-`) within `src`, or nil when the name has no definition form."
  [src nm]
  (let [lines (split src "\n")]
    (loop [i 0]
      (if (>= i (count lines))
        nil
        (let [line (get lines i)
              hit (some (fn [head]
                          (let [pfx (str head nm)
                                k (index-of line pfx)]
                            (when (and (some? k)
                                       (name-boundary? line (+ k (count pfx))))
                              {:line (inc i) :col (inc (+ k (count head)))})))
                        ["(defn " "(defn- "])]
          (if (some? hit) hit (recur (inc i))))))))

(defn- point-range
  "An LSP range spanning the name token at [line col]."
  [text line col nm]
  {"start" (bl->lsp text line col)
   "end" (bl->lsp text line (+ col (count nm)))})

(defn- line-range
  "An LSP range spanning the whole of 1-based `line` (clamped: `line-text`)."
  [text line]
  (let [[line l] (line-text text line)]
    {"start" (bl->lsp text line 1)
     "end" {"line" (dec line) "character" (utf16-length l)}}))

(defn- line-end
  "The LSP position just past the last character of 1-based `line`."
  [text line]
  (let [[line l] (line-text text line)]
    {"line" (dec line) "character" (utf16-length l)}))

(def ^:private zero-range
  {"start" {"line" 0 "character" 0} "end" {"line" 0 "character" 0}})
```

## Envelopes

Three shapes cross the wire: a response carrying a result, an error response,
and a notification. Each lowers its payload through `json-safe` so the writer
never has to know what a beam-lisp vector is.

```beam-lisp
(defn- response [id result]
  {"jsonrpc" "2.0" "id" id "result" (json-safe result)})

(defn- error-resp [id code message]
  {"jsonrpc" "2.0" "id" id "error" {"code" code "message" message}})

(defn- notification [method params]
  {"jsonrpc" "2.0" "method" method "params" (json-safe params)})

(defn parse-error
  "The response to an unframable inbound message: JSON-RPC -32700."
  [reason]
  (error-resp nil -32700 (str "Parse error: " (name reason))))

(defn internal-error
  "The response to a handler that raised: JSON-RPC -32603. The message stays
   the constant the spec intends (a category, not a report); `detail` — which
   method raised and why — rides in the error's `data`, and on the server's
   stderr, where the client log surfaces it."
  [id detail]
  (let [r (error-resp id -32603 "Internal error")]
    (if (nil? detail) r (assoc-in r ["error" "data"] detail))))
```

## Capabilities

The advertised set IS the handled set: each key here has a `handle` branch, and
nothing is offered that the server cannot answer.

```beam-lisp
(defn capabilities []
  {"textDocumentSync" {"openClose" true "change" 1 "save" true}
   "hoverProvider" true
   "definitionProvider" true
   "referencesProvider" true
   "documentHighlightProvider" true
   "documentSymbolProvider" true
   "completionProvider" {"triggerCharacters" ["(" " "]}
   "signatureHelpProvider" {"triggerCharacters" ["(" " "]}
   "inlayHintProvider" true
   "codeActionProvider" {"codeActionKinds" ["quickfix" "refactor"]}})

(defn- server-info []
  {"name" "beam-lisp" "version" "0.1.0"})
```

## Diagnostics

The compiler's warnings — type errors, effect and linearity smells — become
squiggles. `lsp/diagnostics` is pure, so a publish is just a notification
carrying its lowered result; the empty list matters as much as a full one, since
it is how a closed or clean document clears its squiggles.

```beam-lisp
(defn- diagnostic->lsp [text d]
  (let [sl (or (get d :line) 1)
        sc (or (get d :col) 1)
        el (or (get d :end-line) sl)
        ec (or (get d :end-col) (inc sc))]
    {"range" {"start" (bl->lsp text sl sc) "end" (bl->lsp text el ec)}
     "severity" 1
     "source" "beam-lisp"
     "message" (str (get d :msg ""))}))

(defn- parseable?
  "Whether the reader accepts `text`. Mid-edit text often does not; the
   answer is recorded on the doc so every position feature can degrade to its
   empty result instead of raising -32603 on each keystroke."
  [text]
  (try (BeamLisp.Reader/read_string text) true (catch _e false)))

(def ^:private feature-empty
  "Every position feature's empty answer — what it returns when the document
   does not parse. The parse-error diagnostic already carries the why."
  {"textDocument/hover" nil
   "textDocument/definition" nil
   "textDocument/references" []
   "textDocument/documentHighlight" []
   "textDocument/documentSymbol" []
   "textDocument/completion" []
   "textDocument/signatureHelp" nil
   "textDocument/inlayHint" []
   "textDocument/codeAction" []
   "$/beamlisp/proof" nil
   "$/beamlisp/nativeEligible" nil
   "$/beamlisp/impact" []
   "$/beamlisp/deadCode" []})

(defn- doc-unparseable?
  "Whether the doc for this request's uri is present and known unparseable."
  [state params]
  (let [uri (or (get-in params ["textDocument" "uri"]) (get params "uri"))
        d (doc-of state uri)]
    (and (some? d) (= false (:parseable d)))))

(defn- publish-diagnostics [state uri]
  (let [d (doc-of state uri)
        text (:text d)
        ns (or (:ns d) "user")
        ;; An edit in flight is often unbalanced. The reader refuses it, so
        ;; answer with one parse-error diagnostic at the top instead of letting
        ;; the whole publish raise: the server stays up and the editor shows a
        ;; squiggle on the document being typed. The LOWERING rides inside the
        ;; try with the analysis, because a publish has one job — never take
        ;; the didOpen down with it — and the analysis is only one of the two
        ;; things that can fail on the way to the wire.
        ds (try (into [] (map (fn [x] (diagnostic->lsp text x))
                              (lsp/diagnostics text ns)))
                (catch e [(diagnostic->lsp text {:msg (str "parse error: " (ex-message e))
                                                 :line 1 :col 1})]))]
    (notification "textDocument/publishDiagnostics"
                  {"uri" uri
                   "diagnostics" ds})))
```

## Hover, with the proof card

Standard hover names the expression under the cursor. When that expression is a
call to a user function, the server appends what the compiler PROVED about it —
purity, termination, return tagset, callees — because `lsp/proof-hover` answers
exactly that. The beyond-LSP intelligence therefore reaches every editor, with
no plugin: it rides the one request every editor already sends.

```beam-lisp
(defn- proof-markdown [p]
  (str "**" (:fn p) "** — "
       (if (:pure p) "pure" "effects")
       (if (:terminates p) " · terminates" " · may-diverge")
       " · returns " (pr-str (into [] (:returns p)))
       (if (seq (:calls p))
         (str " · calls " (join ", " (into [] (:calls p))))
         "")))

(defn- name-token-end
  "The 0-based end index (exclusive) of the name token starting at `from` in
   `line`: the first delimiter."
  [line from]
  (let [n (count line)]
    (loop [i from]
      (if (or (>= i n) (name-boundary? line i))
        i
        (recur (inc i))))))

(defn- defn-name-at
  "The name of the top-level defn whose NAME TOKEN contains [line col]
   (1-based), or nil. find-defn goes name → position; this goes the other
   way, so pointing AT a definition's head is as answerable as pointing at a
   call."
  [text line col]
  (let [line-text (get (split text "\n") (dec line))]
    (when (some? line-text)
      (first
       (filter some?
        (map (fn [head]
               (let [k (index-of line-text head)]
                 (when (some? k)
                   (let [start (+ k (count head))
                         end (name-token-end line-text start)]
                     ;; col is 1-based; token spans (start, end] in 1-based terms
                     (when (and (> end start) (>= (dec col) start) (< (dec col) end))
                       (subs line-text start end))))))
             ["(defn " "(defn- "]))))))

(defn- hover-value [text line col]
  (let [hv (lsp/hover text line col)
        d (lsp/definition text line col)
        nm (:resolves-to d)
        card (when (and (some? nm) (= :user-fn (:kind d)))
               (lsp/proof-hover text nm))]
    (cond
      (some? card) (str hv "\n\n---\n\n" (proof-markdown card))
      ;; pointing at a definition's own head answers its proof card — the
      ;; most natural place to ask "what does this fn do" cannot stay ∅
      (= "∅ nothing here" hv) (let [dn (defn-name-at text line col)]
                                (if (nil? dn)
                                  hv
                                  (proof-markdown (lsp/proof-hover text dn))))
      :else hv)))

(defn- hover-out [state params id]
  (let [uri (get-in params ["textDocument" "uri"])
        pos (or (get params "position") {})
        d (doc-of state uri)]
    (if (nil? d)
      [state [(response id nil)]]
      (let [text (:text d)
            bl (lsp->bl text (get pos "line") (get pos "character"))
            value (hover-value text (:line bl) (:col bl))]
        [state [(response id {"contents" {"kind" "markdown" "value" value}})]]))))
```

## Definition, references, highlight

All three resolve a name at the cursor through the call graph and then map the
name back to text spans: definition answers the defining head, references and
highlight answer the real call SITES the ANF walk finds (including a script's
top-level uses, which live in the synthetic `<top>` body). A `:host` callee
(an Erlang or Elixir function) has no source to jump to, so definition answers
null — honest about the boundary of what the program owns.

```beam-lisp
(defn- definition-out [state params id]
  (let [uri (get-in params ["textDocument" "uri"])
        pos (or (get params "position") {})
        d (doc-of state uri)]
    (if (nil? d)
      [state [(response id nil)]]
      (let [text (:text d)
            bl (lsp->bl text (get pos "line") (get pos "character"))
            res (lsp/definition text (:line bl) (:col bl))
            nm (or (:resolves-to res) (defn-name-at text (:line bl) (:col bl)))
            kind (if (some? (:resolves-to res)) (:kind res) :user-fn)
            p (when (and (some? nm) (= :user-fn kind)) (find-defn text nm))]
        [state [(response id
                          (if (nil? p)
                            nil
                            {"uri" uri "range" (point-range text (:line p) (:col p) nm)}))]]))))

(defn- references-out [state params id]
  (let [uri (get-in params ["textDocument" "uri"])
        pos (or (get params "position") {})
        d (doc-of state uri)]
    (if (nil? d)
      [state [(response id [])]]
      (let [text (:text d)
            bl (lsp->bl text (get pos "line") (get pos "character"))
            target (or (:resolves-to (lsp/definition text (:line bl) (:col bl)))
                       (defn-name-at text (:line bl) (:col bl)))]
        (if (nil? target)
          [state [(response id [])]]
          ;; call SITES, not caller defns: the ANF walk finds real occurrences
          ;; (including the synthetic <top>'s, so a script's use of a fn is a
          ;; reference like any other); includeDeclaration adds the head.
          (let [sites (into [] (lsp/document-highlight text target))
                locs (into []
                       (map (fn [s]
                              {"uri" uri
                               "range" {"start" (bl->lsp text (:line s) (:col s))
                                        "end" (bl->lsp text (:line s) (:end-col s))}})
                            sites))
                decl (if (get-in params ["context" "includeDeclaration"])
                       (let [p (find-defn text target)]
                         (if (nil? p)
                           []
                           [{"uri" uri "range" (point-range text (:line p) (:col p) target)}]))
                       [])]
            [state [(response id (into [] (concat decl locs)))]]))))))

(defn- highlight-out [state params id]
  (let [uri (get-in params ["textDocument" "uri"])
        pos (or (get params "position") {})
        d (doc-of state uri)]
    (if (nil? d)
      [state [(response id [])]]
      (let [text (:text d)
            bl (lsp->bl text (get pos "line") (get pos "character"))
            target (:resolves-to (lsp/definition text (:line bl) (:col bl)))
            spans (if (some? target) (into [] (lsp/document-highlight text target)) [])]
        [state [(response id
                          (into [] (map (fn [s]
                                          {"range" {"start" (bl->lsp text (:line s) (:col s))
                                                    "end" (bl->lsp text (:line s) (:end-col s))}})
                                        spans)))]]))))
```

## Document symbols, completion, signature help, inlay hints

Each is a projection of the same analysis with the LSP detail field carrying
what the compiler proved. `detail` is where `→ (:int) · pure · ↓` lives; the
symbol kind is Function.

```beam-lisp
(defn- symbol-detail [s]
  (str "→ " (pr-str (into [] (:returns s)))
       (if (:pure s) " · pure" " · effects")
       (if (:terminates s) " · ↓" " · ⟳?")))

(defn- symbol->lsp [text s]
  (let [nm (:name s)
        p (find-defn text nm)]
    {"name" nm
     "kind" 12
     "range" (if (some? p) (line-range text (:line p)) zero-range)
     "selectionRange" (if (some? p) (point-range text (:line p) (:col p) nm) zero-range)
     "detail" (symbol-detail s)}))

(defn- document-symbols-out [state params id]
  (let [uri (get-in params ["textDocument" "uri"])
        d (doc-of state uri)]
    (if (nil? d)
      [state [(response id [])]]
      (let [text (:text d)
            syms (into [] (lsp/document-symbols text))]
        [state [(response id (into [] (map (fn [s] (symbol->lsp text s)) syms)))]]))))

(defn- completion-out [state params id]
  (let [uri (get-in params ["textDocument" "uri"])
        pos (or (get params "position") {})
        d (doc-of state uri)]
    (if (nil? d)
      [state [(response id [])]]
      (let [text (:text d)
            bl (lsp->bl text (get pos "line") (get pos "character"))
            items (into [] (lsp/completion text (:line bl) (:col bl)))]
        [state [(response id
                          (into [] (map (fn [c] {"label" (:label c)
                                                 "detail" (:detail c)
                                                 "kind" 3})
                                        items)))]]))))

(defn- signature-out [state params id]
  (let [uri (get-in params ["textDocument" "uri"])
        pos (or (get params "position") {})
        d (doc-of state uri)]
    (if (nil? d)
      [state [(response id nil)]]
      (let [text (:text d)
            bl (lsp->bl text (get pos "line") (get pos "character"))
            sh (lsp/signature-help text (:line bl) (:col bl))]
        [state [(response id
                          (when (some? sh)
                            {"signatures" [{"label" (:label sh)}]}))]]))))

(defn- inlay-out [state params id]
  (let [uri (get-in params ["textDocument" "uri"])
        d (doc-of state uri)]
    (if (nil? d)
      [state [(response id [])]]
      (let [text (:text d)
            hs (into [] (lsp/inlay-hints text))]
        [state [(response id
                          (into [] (map (fn [h]
                                          (let [p (find-defn text (:fn h))]
                                            {"position" (line-end text (if (some? p) (:line p) 1))
                                             "label" (:hint h)}))
                                        hs)))]]))))

(defn- code-action-out [state params id]
  (let [uri (get-in params ["textDocument" "uri"])
        ;; codeAction sends a RANGE, not a position — the point is its start
        pos (or (get params "position")
                (get-in params ["range" "start"])
                {})
        d (doc-of state uri)]
    (if (nil? d)
      [state [(response id [])]]
      (let [text (:text d)
            ns (or (:ns d) "user")
            bl (lsp->bl text (get pos "line") (get pos "character"))
            acts (into [] (lsp/code-actions text ns (:line bl) (:col bl)))]
        [state [(response id
                          (into [] (map (fn [a] {"title" (:title a)
                                                 "kind" (if (= :quickfix (:kind a))
                                                         "quickfix" "refactor")})
                                        acts)))]]))))
```

## Beyond-LSP requests

The proof-backed queries have no standard LSP request. They are reachable as
custom methods in the `$/beamlisp/` namespace, so an editor extension can call
them; the standard-mechanism twin (the hover proof card, `detail` on a symbol)
shows the same facts without one.

```beam-lisp
(defn- custom-out [state params id method]
  (let [uri (get params "uri")
        d (doc-of state uri)]
    (if (nil? d)
      [state [(response id nil)]]
      (let [text (:text d)
            nm (get params "fn")]
        (cond
          (= method "$/beamlisp/proof")
          [state [(response id (lsp/proof-hover text nm))]]

          (= method "$/beamlisp/nativeEligible")
          [state [(response id (lsp/native-eligible text nm))]]

          (= method "$/beamlisp/impact")
          [state [(response id (into [] (lsp/impact text nm)))]]

          (= method "$/beamlisp/deadCode")
          [state [(response id (into [] (lsp/dead-code text (or (get params "roots") []))))]]

          :else
          [state [(error-resp id -32601 (str "Method not found: " method))]])))))
```

## The dispatch

`handle` is the whole protocol in one function of (state, message). Lifecycle
methods move the flags; document methods move the document map and publish
diagnostics in the same turn; feature methods answer from the stored text. A
request before `initialize` is refused with -32002, an unknown request with
-32601, and an unknown notification is ignored — exactly as the spec requires.

```beam-lisp
(defn handle
  "One inbound message → [state' out]. Pure: no ports, no globals."
  [state msg]
  (let [method (get msg "method")
        id (get msg "id")
        params (or (get msg "params") {})
        has-id (contains? msg "id")
        initialized (:initialized? state)]
    (cond
      (= method "initialize")
      [(assoc state :initialized? true
                    :root (or (get-in params ["rootUri"]) (get-in params ["rootPath"])))
       [(response id {"capabilities" (capabilities) "serverInfo" (server-info)})]]

      (= method "initialized") [state []]
      (= method "shutdown") [(assoc state :shutdown? true) [(response id nil)]]
      (= method "exit") [(assoc state :exit? true) []]

      (= method "textDocument/didOpen")
      (let [td (get params "textDocument")
            uri (get td "uri")
            text (get td "text")
            state' (assoc-in state [:docs uri]
                             {:text text :version (get td "version") :ns (ns-of text)
                              :parseable (parseable? text)})]
        [state' [(publish-diagnostics state' uri)]])

      (= method "textDocument/didChange")
      (let [uri (get-in params ["textDocument" "uri"])
            changes (get params "contentChanges")
            text (get (last changes) "text")
            state' (assoc-in state [:docs uri]
                             {:text text
                              :version (get-in params ["textDocument" "version"])
                              :ns (ns-of text)
                              :parseable (parseable? text)})]
        [state' [(publish-diagnostics state' uri)]])

      (= method "textDocument/didSave")
      (let [uri (get-in params ["textDocument" "uri"])]
        [state [(publish-diagnostics state uri)]])

      (= method "textDocument/didClose")
      (let [uri (get-in params ["textDocument" "uri"])]
        [(update state :docs dissoc uri)
         [(notification "textDocument/publishDiagnostics" {"uri" uri "diagnostics" []})]])

      (and has-id (not initialized))
      [state [(error-resp id -32002 "Server not initialized")]]

      ;; Mid-edit text often does not parse; every position feature then
      ;; answers its empty result — the parse-error diagnostic carries the why.
      (and has-id
           (contains? feature-empty method)
           (doc-unparseable? state params))
      [state [(response id (get feature-empty method))]]

      (and has-id (= method "textDocument/hover")) (hover-out state params id)
      (and has-id (= method "textDocument/definition")) (definition-out state params id)
      (and has-id (= method "textDocument/references")) (references-out state params id)
      (and has-id (= method "textDocument/documentHighlight")) (highlight-out state params id)
      (and has-id (= method "textDocument/documentSymbol")) (document-symbols-out state params id)
      (and has-id (= method "textDocument/completion")) (completion-out state params id)
      (and has-id (= method "textDocument/signatureHelp")) (signature-out state params id)
      (and has-id (= method "textDocument/inlayHint")) (inlay-out state params id)
      (and has-id (= method "textDocument/codeAction")) (code-action-out state params id)

      (and has-id (= method "$/beamlisp/proof")) (custom-out state params id method)
      (and has-id (= method "$/beamlisp/nativeEligible")) (custom-out state params id method)
      (and has-id (= method "$/beamlisp/impact")) (custom-out state params id method)
      (and has-id (= method "$/beamlisp/deadCode")) (custom-out state params id method)

      has-id [state [(error-resp id -32601 (str "Method not found: " method))]]
      :else [state []])))
```
