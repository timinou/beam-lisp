# bl.repl — a read-eval-print loop for beam-lisp

A REPL reads a form, evaluates it, prints the value, and repeats. The work is
in "reads a form": a form spans lines, so the loop cannot hand each line to
the evaluator. It reads a line, counts the parentheses, and keeps reading
until the form is complete. A `(` inside a string or a `;` comment is text,
not structure, and counting it would make the loop wait for a closer that
never comes — so the counter is a small scanner, not a character count.

The loop is written in beam-lisp because `bl` is the one interface to the
language. It never halts a process: it returns 0 at end of input, errors print
and the loop continues, and the daemon can serve a session inside a warm VM.

```beam-lisp
(ns bl.repl)
```

## Is the form complete?

`balanced?` walks the text once. A `"` opens a string, where brackets and
semicolons are ordinary characters; `\` escapes the next character inside it.
A `;` opens a comment that ends at the newline. Every opener pushes the closer
it needs; every closer must match the top of the stack. The text is complete
when the stack is empty and no string is open. An unterminated string is
incomplete on purpose: the user is still typing it, and the next line may
close it.

```beam-lisp
(defn balanced?
  "True when `src` holds only complete forms: every opener has its matching
   closer and no closer is unmatched. Strings and `;` comments are skipped, so
   a bracket inside either is ordinary text. An unterminated string is
   incomplete, so the repl reads another line."
  [src]
  (let [gs (vec (String/graphemes src))]
    (loop [i 0 stack [] str? false esc? false comment? false]
      (if (>= i (count gs))
        (and (empty? stack) (not str?))
        (let [ch (get gs i)
              n (inc i)]
          (cond
            comment? (recur n stack str? esc? (= ch "\n"))
            esc?     (recur n stack str? false false)
            str?     (if (= ch "\\")
                       (recur n stack true true false)
                       (recur n stack (not= ch "\"") false false))
            (= ch "\"") (recur n stack true false false)
            (= ch ";")  (recur n stack false false true)
            (= ch "(")  (recur n (cons ")" stack) false false false)
            (= ch "[")  (recur n (cons "]" stack) false false false)
            (= ch "{")  (recur n (cons "}" stack) false false false)
            (or (= ch ")") (= ch "]") (= ch "}"))
            (if (= ch (first stack))
              (recur n (rest stack) false false false)
              false)
            :else (recur n stack false false false)))))))
```

## The loop

The prompt names the current namespace, so the user can see where a form will
land. A continuation line uses a short prompt; a form that is still open is
not a new form.

The last three results stay reachable the way a Clojure session expects: `*1`
is the last value, `*2` the one before it, and `*e` the last error. They are
interned in `user`, the namespace a prompt reads and writes by default.

```beam-lisp
(defn- last-value [name]
  (try (BeamLisp.Env/fetch! "user" name) (catch _ nil)))

(defn- record! [v]
  (BeamLisp.Env/intern "user" "*2" (last-value "*1"))
  (BeamLisp.Env/intern "user" "*1" v))

(defn- show
  "Evaluate one complete form, print its value, and keep the session's last
   values current. An error prints `error: msg` and the loop continues — an
   error is one form's outcome, not the session's."
  [src]
  (if (= "" (String/trim src))
    nil
    (try
      (let [v (BeamLisp/eval src)]
        (record! v)
        (println (BeamLisp.RT/print_str v)))
      (catch e
        (BeamLisp.Env/intern "user" "*e" e)
        (println (str "error: " (ex-message e)))))))

(defn- read-form
  "Read one complete form: prompt, read a line, and keep reading while the
   accumulated text is incomplete. Blank lines read as nothing. Returns the
   source, or `:eof` when input ends before a form starts."
  []
  (loop [acc ""]
    (let [line (IO/gets (if (= acc "") (str (BeamLisp.Env/current_ns) "=> ") "   "))]
      (cond
        (or (= line :eof) (nil? line)) (if (= acc "") :eof acc)
        (and (= acc "") (= "" (String/trim line))) (recur "")
        :else (let [acc (str acc line)]
                (if (balanced? acc) acc (recur acc)))))))

(defn run
  "The interactive session `bl repl` and a bare `bl` enter. Reads forms until
   end of input, evaluates each in `user`, and returns exit code 0. Never
   halts, so a daemon request can drive it."
  [_args _st]
  (BeamLisp.Env/in_ns "user")
  (println "beam-lisp on the BEAM — Ctrl+D to exit")
  (loop []
    (let [src (read-form)]
      (if (= src :eof)
        0
        (do (show src) (recur))))))
```

