# The first hour with `bl`

*A runnable walkthrough. The cells below write a small project under
`tmp/bl-first-hour/`; the shell blocks show what to type and what comes back.
Run `bl doc run docs/bl/01-first-hour.bl.md` to (re)create the files.*

You need a `bl` — the drop, or `mix bl` inside the beam-lisp checkout. Every
command below works with either spelling; this page writes `bl`.

The walkthrough builds a tiny project as it goes:

```beam-lisp
(ns bl.first-hour)

(do (File/mkdir_p! "tmp/bl-first-hour/src")
    (File/mkdir_p! "tmp/bl-first-hour/test")
    :ok)
```

```bl-result cell0
:ok
```

## Run a program

A beam-lisp program is a file; the last value is printed.

```beam-lisp
(File/write! "tmp/bl-first-hour/hello.bl"
             "(println \"hello from beam-lisp\")\n(+ 20 22)\n")
```

```bl-result cell1
:ok
```

```sh
$ cd tmp/bl-first-hour
$ bl run hello.bl
hello from beam-lisp
42
```

`println` is a side effect and shows on stdout; `42` is the file's last value,
which `bl run` prints for you.

## Evaluate one expression

For a single expression there is no file to make.

```sh
$ bl eval '(+ 1 2)'
3
$ bl eval '(map inc [1 2 3])'
(2 3 4)
```

## Read from a pipe

`-` means standard input. `bl run -` runs a program fed in; `bl eval -`
evaluates one expression fed in.

```sh
$ printf '(println "from stdin")\n(+ 20 22)\n' | bl run -
from stdin
42
$ printf '(* 6 7)\n' | bl eval -
42
```

## Open a session

`bl repl` — or just `bl` — reads a form, evaluates it, prints the value, and
waits. A form may span lines; the prompt continues while one is open. `*1` is
the previous value.

```sh
$ bl repl
beam-lisp on the BEAM — Ctrl+D to exit
user=> (+ 1 2)
3
user=> (* *1 10)
30
user=> (map (fn [x] (* x x))
     [1 2 3])
(1 4 9)
user=>
```

## Write a test, run it

A test file declares a namespace and uses `deftest` / `is`.

```beam-lisp
(File/write! "tmp/bl-first-hour/test/hello_test.bl"
             "(ns hello-test)\n\n(deftest arithmetic\n  (is (= 4 (+ 2 2)))\n  (is (= 6 (* 2 3))))\n")
```

```bl-result cell2
:ok
```

`bl test` runs `test/` by default.

```sh
$ bl test
Testing hello-test

Ran 1 tests containing 2 assertions.
0 failures, 0 errors.
```

## Find a smell, fix it

Write a source with two habits the language has shorter words for — an
`if` around a negated test, and a comparison against zero.

```beam-lisp
(File/write! "tmp/bl-first-hour/src/greet.bl"
             "(ns greet)\n\n(defn negative? [n]\n  (if (not (< n 0)) false true))\n\n(defn address [who]\n  (str \"hello, \" who))\n")
```

```bl-result cell3
:ok
```

`bl lint` reads `src/` by default and reports each one with the line, the rule,
and the rewrite:

```sh
$ bl lint
src/greet.bl:4  if→if-not [safe]
    (if (not (< n 0)) false true)
  → (if-not (< n 0) false true)
src/greet.bl:4  <-0→neg? [idiomatic]
    (< n 0)
  → (neg? n)
2 smells in 1 file
```

`bl fix` applies them in place, changing only the tokens the rules spell:

```sh
$ bl fix
fixed src/greet.bl (2)
1 file changed, 0 literate files skipped
$ bl lint
0 smells in 1 file
```

The file now reads:

```clojure
(ns greet)

(defn negative? [n]
  (if-not (neg? n) false true))

(defn address [who]
  (str "hello, " who))
```

## Set a baseline, catch a regression

`bl check` measures every source and compares it to `.bl-check.edn`. There is
none yet, so the first run is a measurement:

```sh
$ bl check
hello.bl  diags=0 smells=0 fns=0 pure=0 eligible=0
src/greet.bl  diags=0 smells=0 fns=2 pure=0 eligible=0
test/hello_test.bl  diags=0 smells=0 fns=0 pure=0 eligible=0
no baseline: run bl check --update to create .bl-check.edn
ok
```

Record it:

```sh
$ bl check --update
wrote .bl-check.edn (3 files)
```

Now introduce a smell — an `if` around a negation again:

```beam-lisp
(File/write! "tmp/bl-first-hour/src/greet.bl"
             "(ns greet)\n\n(defn negative? [n]\n  (if-not (neg? n) false true))\n\n(defn address [who]\n  (if (not (= who \"\")) (str \"hello, \" who) \"hello\"))\n")
```

```bl-result cell4
:ok
```

The next check fails, and names the file and the count that moved:

```sh
$ bl check
hello.bl  diags=0 smells=0 fns=0 pure=0 eligible=0
src/greet.bl  diags=0 smells=2 fns=2 pure=0 eligible=0
test/hello_test.bl  diags=0 smells=0 fns=0 pure=0 eligible=0
✗ smells 0 → 2 (src/greet.bl)
✗ 1 regression(s)
```

`bl fix` clears it:

```sh
$ bl fix
fixed src/greet.bl (1)
1 file changed, 0 literate files skipped
```

When the changes are good, `bl check --update` accepts the new state as the
baseline. `bl check --install-hook` makes that check run before every commit —
see [00-the-cli.md](00-the-cli.md#the-baseline-and-the-pre-commit-hook).

## Where to go next

- [00-the-cli.md](00-the-cli.md) — every verb, flag, and exit code.
- [02-the-verify-loop.bl.md](02-the-verify-loop.bl.md) — what the compiler
  *proves* about a function, and how to ask the codebase questions.
- [03-the-live-loop.md](03-the-live-loop.md) — keep a program running and
  reload it on save.
