# Calling a value

A call is where two things meet: a value, and the arguments it is handed. When
they do not fit, the reader needs both halves back — *which* value, and *how
many* arguments. A call that fails in silence about either one sends the reader
into the runtime's own vocabulary, which is not a place anyone should have to
go.

## What is a function

Anything with an answer for its arguments. Seven shapes answer:

| shape | `(v a…)` means | arity |
|---|---|---|
| a fn | call it | whatever its parameter list declares |
| a keyword | your own name, looked up | 1, or 2 with a default |
| a map | the key, looked up | 1, or 2 with a default |
| a set | the member, or `nil` | 1, or 2 with a default |
| a sorted map | the key, looked up | 1, or 2 with a default |
| a sorted set | the member, or `nil` | 1, or 2 with a default |
| a vector | the element at that index | 1 |

```clojure
(:b {:a 1 :b 2})           ; => 2
({:a 1} :a)                ; => 1
(#{1 2} 2)                 ; => 2
([10 20] 1)                ; => 20
((fn [x] (inc x)) 41)      ; => 42
({:a 1} :missing :none)    ; => :none
```

The second argument is the default, which is what lets `(get m k default)` be
written `(m k default)`. Membership reads as a lookup of itself, so
`(#{1 2} 9)` is `nil` — a set answers for its members and declines the rest.

## A call that cannot work says what was called

```
a map called with 0 arguments — a map is a function of its keys: ({:a 1} :a), or with a default: ({:a 1} :zz :none)
a vector called with 2 arguments — a vector is a function of its index: ([10 20] 1)
a fn called with 3 arguments — a fn of 0/1/2 arguments
a fn called with 0 arguments — a variadic fn taking 1 or more arguments
cannot call 7 — a number is not a function
cannot call nil — nil is not a function
```

One sentence, in the same shape every time: what was called, with how many
arguments, and what it takes instead. The value is printed *bounded* — a mistake
is not an excuse to flood a log, and which value was wrong is visible in its
first few elements.

The sentence is a value like any other, so a program reports its own mistakes:

```clojure
(try
  (build-report)
  (catch e (println "report failed:" (ex-message e))))
```

## Where a bad call is refused

Three layers can see a wrong call, and the earliest one that can is the one that
answers.

| what the head is | who refuses it | how it reads |
|---|---|---|
| a literal the reader can see — `(7 1)`, `("s" 0)`, `({:a 1})` | the compiler | `line 2: cannot call 7 — a number is not a function`, with no stack at all |
| a name whose type inference knows | the type checker, as a warning | `m is called with 0 arguments — a map takes 1 or 2` |
| anything else — a value from a map, a field, a call | the runtime | the same sentence, at the point of the call |

The compiler's refusal is two lines: the position and the sentence, then the
form it is about (`  offending form: 7`). The runtime's is one line — by the
time a value is being called there is no source position left to give.

The second layer WARNS rather than refuses, and stays quiet about a value it
cannot type. Inference is sound but partial: a checker that can be wrong about a
correct program is worse than a quiet one. It also declines to check the arity
of anything that might be a fn, because a fn carries its own arity and its type
does not: `(get handlers :create)` is a union that includes fns, and one of
those may be called with any number of arguments at all.

A literal head is refused at compile time because it is knowable then. The
guards are narrow so that the heads which *do* work are untouched:

```clojure
({:a 1} :a)      ; compiles — a map literal is callable
([10 20] 0)      ; compiles
(#{1 2} 1)       ; compiles
(:a {:a 1})      ; compiles
({:a 1})         ; refused: a map takes 1 or 2, not 0
```

## A local shadows the global it is named after

A parameter named `comp` is a fn, and `(comp a b)` calls the parameter rather
than `core/comp`. A binding named `max` that holds an integer is not callable,
so `(max h max)` reaches `core/max`. The rule is CALLABILITY: the local's value
is invoked when it has an answer for these arguments, and otherwise the global
of that name runs.

That rule is why the shapes above live in one list. `invoke` decides what
actually runs, and a dispatch that disagrees with it answers *wrongly* instead
of failing — a lookup where a call was meant, with no error to notice it by.
