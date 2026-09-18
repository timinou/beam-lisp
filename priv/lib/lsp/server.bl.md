# lsp.server — the stdio loop that carries LSP to an editor

An editor starts the language server as a child process and talks to it over
that process's standard input and output. This namespace is the child: it reads
`Content-Length`-framed JSON from stdin, hands each message to `lsp.rpc/handle`,
and writes every message `handle` answers back to stdout in the same framing.

Two rules keep it honest as a transport:

- **stdout carries protocol only.** One stray `println` corrupts the frame
  stream and the editor's parser breaks. Every diagnostic this server emits
  goes to stderr, never to stdout.
- **the loop never dies on a bad message.** A malformed frame becomes a -32700
  error response, a raising handler becomes -32603, and the next frame is read
  as if nothing happened.

The loop ends at `exit` or at end of input, and `run` returns an exit code so
`bl lsp serve` behaves like any other `bl` verb.

```beam-lisp
(ns lsp.server
  (:require [lsp.rpc :as rpc]
            [bl.util :as u]))
```

## Reading one frame

A frame is a run of `key: value\r\n` header lines, an empty line, then exactly
`Content-Length` bytes of JSON. Reading it needs two primitives: a line read for
the headers (which returns as soon as a line arrives, so an interactive client
is never made to wait) and a byte-count read for the body (which blocks until
the frame is whole). An `:eof` or error tuple from either is treated as end of
input.

```beam-lisp
(defn- eof? [x] (or (= x :eof) (nil? x)))

(defn- read-line []
  (try (IO/binread :stdio :line) (catch _e :eof)))

(defn- read-bytes [n]
  (try (IO/binread :stdio n) (catch _e :eof)))

(defn- strip-cr [s] (if (ends-with? s "\r") (subs s 0 (dec (count s))) s))

(defn- parse-header
  "One `key: value` header line → [lowercased-key value], or nil."
  [line]
  (let [l (String/trim (strip-cr line))
        i (index-of l ":")]
    (when (some? i)
      [(String/downcase (String/trim (subs l 0 i)))
       (String/trim (subs l (inc i)))])))

(defn read-frame
  "Read one framed message from standard input.

   → {:msg map}         a decoded JSON-RPC message
   → :eof               end of input
   → {:error reason}    a malformed frame (:missing-content-length, :bad-json,
                        :bad-content-length); the stream resynchronizes after"
  []
  (loop [headers {}]
    (let [line (read-line)]
      (cond
        (eof? line) :eof
        (not (string? line)) :eof
        :else
        (let [t (String/trim (strip-cr line))]
          (if (= t "")
            (let [n (get headers "content-length")]
              (if (nil? n)
                {:error :missing-content-length}
                (try
                  (let [want (String/to_integer n)
                        body (read-bytes want)]
                    (cond
                      (eof? body) :eof
                      (not (string? body)) :eof
                      (< (erlang/byte_size body) want) :eof
                      :else (try {:msg (bl.json/decode body)}
                                  (catch _e {:error :bad-json}))))
                  (catch _e {:error :bad-content-length}))))
            (let [kv (parse-header line)]
              (if (nil? kv)
                (recur headers)
                (recur (assoc headers (get kv 0) (get kv 1)))))))))))
```

## The loop

Each message goes through `lsp.rpc/handle`, whose only job is to say what to
send next. The writer frames and flushes every message, the loop stops when the
state says `exit`, and a raising handler is answered with -32603 rather than
allowed to end the process.

```beam-lisp
(defn- write-all [msgs]
  ;; On the latin1 device `run` installs, `binwrite` is byte-transparent: the
  ;; JSON bytes go out exactly as `encode-frame` produced them. (On a unicode
  ;; device binwrite would re-encode them and desynchronize Content-Length.)
  (reduce (fn [_ m] (IO/binwrite :stdio (rpc/encode-frame m)) nil) nil msgs))

(defn run
  "Speak LSP on stdin/stdout until `exit` or end of input. Returns an exit
   code: 0 on a clean end."
  [_args st]
  (u/register-paths st)
  ;; The protocol is bytes: Content-Length counts bytes, not characters. A
  ;; unicode-encoded stdio device refuses a byte read whose content is not
  ;; translatable (`{:no_translation, :unicode, :latin1}` on any multi-byte
  ;; body). Latin1 makes the device byte-transparent in both directions: one
  ;; read byte is one binary byte, and one written byte is emitted as-is.
  (io/setopts :standard_io (list (erlang/list_to_tuple (list :encoding :latin1))))
  (loop [state (rpc/initial-state)]
    (let [fr (read-frame)]
      (cond
        (= fr :eof) 0

        (contains? fr :error)
        (do (u/io-err (str "bl lsp serve: " (name (:error fr))))
            (write-all [(rpc/parse-error (:error fr))])
            (recur state))

        :else
        (let [msg (:msg fr)
              res (try (rpc/handle state msg)
                       (catch e
                         ;; A raise is a bug in a handler, and the ONLY trace
                         ;; of it is what we say here — so say everything:
                         ;; the method, the exception, on stderr always, and
                         ;; in the -32603 message when the message is a
                         ;; request (a notification must not get a reply).
                         (let [detail (str (get msg "method") ": "
                                           (or (ex-message e) (pr-str e)))]
                           (u/io-err (str "bl lsp serve: handler raised: " detail))
                           (if (contains? msg "id")
                             [state [(rpc/internal-error (get msg "id") detail)]]
                             [state []]))))
              state' (get res 0)
              out (get res 1)]
          (write-all out)
          (if (:exit? state')
            0
            (recur state')))))))
```
