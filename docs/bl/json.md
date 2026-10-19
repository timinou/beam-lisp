# JSON

`bl.json` turns beam-lisp data into JSON and back. Require it under the name
`json` and write data the way you already do:

```clojure
(ns my.app (:require [bl.json :as json]))

(json/encode {:model "m" :system [{:type "text" :text "hi"}] :tags #{:a}})
;; => "{\"model\":\"m\",\"system\":[{\"text\":\"hi\",\"type\":\"text\"}],\"tags\":[\"a\"]}"

(json/decode "{\"a\":[1,2]}")                 ;; => {"a" [1 2]}
(json/decode "{\"a\":[1,2]}" {:keys :keyword}) ;; => {:a [1 2]}
```

`encode` returns a string, ready to send.

| beam-lisp | JSON |
|---|---|
| map | object; keys sorted, so the output is stable |
| vector, list, set, lazy seq | array |
| keyword, symbol | string, without the `:` |
| string | string |
| integer, float | number |
| `true` `false` | `true` `false` |
| `nil` | `null` |

Decoding gives maps, vectors, strings, numbers, booleans and `nil`.

## When a value has no JSON form

`encode` raises and names the value's type and where it sits, as a JSON
Pointer:

```
bl.json: cannot encode a tuple — no JSON representation (at "/system/0/body")
```

`try-encode` and `try-decode` return `{:ok …}` or `{:error message}` instead of
raising.

## `json/encode` without a require is OTP's

With no `bl.json` alias, `json/encode` and `json/decode` call OTP's `:json`
module. It knows Erlang terms, not beam-lisp data: a vector is a tuple to it,
so `{"system" [{"type" "text"}]}` fails with `unsupported_type`. The compiler
warns at the call:

```
warning: src/app.bl:12: json/encode is OTP's :json, which cannot encode beam-lisp
vectors, sets or keywords. Use bl.json: (:require [bl.json :as json]), …
```

To call OTP's module on purpose, spell it `(erlang/apply :json :encode (list v))`.
