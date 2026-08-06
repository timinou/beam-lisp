# The trust boundary

beam-lisp's compiler treats its input as **code**, not as **data**. That one
choice decides everything in this document.

## What is trusted, and why

A `.bl` file given to `mix beam_lisp.run` — or typed into the REPL — sits at
the same trust level as an Elixir file passed to `Code.eval_string`, or a C
file handed to `cc`. It is **trusted code**: it already has the authority to
call `System.halt/1`, spawn processes, reach `:erlang` directly, and read and
write files on your behalf. Compiling it is not a privilege escalation.

Consequences:

- We make **no effort to sandbox** what a compiled form can do. A hostile
  `.bl` file that is *authorized to run at all* can already do anything the
  host user can. Protecting against that is a job for process/OS boundaries
  (separate BEAM node, container, OS user), not the compiler.
- We **do not** pay a representation tax to make hostile input *safe to even
  compile*. That is the distinction that matters here, and it is the whole
  subject of this document.

## The one hazard: atoms

The BEAM interns symbols and keywords into a finite, process-global atom
table (~1,048,576 entries by default). Atoms are **never garbage-collected**,
and creating an atom when the table is full is not a catchable exception:

```
no more index entries in atom_tab (max=1048576)
Crash dump is being written to: erl_crash.dump...done
```

That is a **whole-VM abort** — every process dies, the node goes down. A
`try/rescue` cannot intercept it. And beam-lisp interns an atom for every
unique symbol and keyword it compiles, so the size of the atom table is
directly proportional to the volume of *unique names* in the input.

For **trusted, hand-written** source this is a non-issue: you cannot type a
million distinct identifiers in a way you would not also notice. But the
moment input becomes **machine-generated** — a CI feed, an agent emitting
forms, fuzzing, a generated schema — the atom table becomes an attack or
accident vector that ends the whole VM. That is a real bug in a language
runtime, not a theoretical one: reading data should never be able to abort
the VM it runs in.

## Why keywords-as-atoms is the right call *for a compiler*

beam-lisp's `:foo` is an **atom** (like Clojure's and jank's), because the
language's semantics require it:

- a keyword is its own identity — `(= :foo :foo)` is `true` for all readers;
- keywords are used as map keys, record/struct tags, and `case`/`cond`
  dispatch labels where identity comparison is the whole point;
- the compiler lowers `{:keyword, "foo"}` straight to the BEAM atom `:foo`,
  so the *user-facing* value is the atom.

Representing `:foo` as a string or a tagged binary internally would break
equality, map lookup, and interop (Elixir code calling into beam-lisp expects
real atoms). So for a compiler, the atom **is** the keyword; there is no
cheap alternative that preserves semantics.

## What a *data* reader would have to do instead

The tension above is specific to **code** input. A reader whose job is to
turn untrusted bytes into *data* — an EDN reader, a JSON parser — can and
should dodge atoms entirely:

- **Tagged binaries, not atoms.** Keep the string form and tag it
  (`{:keyword, "foo"}`, as the beam-lisp reader already does internally).
  Atoms are materialized only at *bounded* intern sites — the handful of
  places the data is actually consumed as an identity value — never in the
  hot read loop.
- **Bounded intern sites.** Even where an atom is unavoidable, intern at a
  known, finite set of positions (e.g. after validating the token is a
  permitted enum), and reject anything outside it. A reader can also keep a
  per-read cache and reuse existing atoms via `String.to_existing_atom/1`
  first, only falling back to interning for genuinely new values.
- **Never grow the table on raw input.** A data reader's contract is: a
  million arbitrary tokens must not permanently consume a million atoms.

This is exactly why the beam-lisp **reader** keeps names as strings
(`{:symbol, "foo"}`, `{:keyword, "ok"}`) even though the **compiler** later
interns them. The reader is already structured like a data reader; the
compiler is where the atom cost is paid — because the compiler's output must
be atoms.

## The guard

Because input is trusted code, we do not chase a representation that avoids
atoms — but we refuse to let a full atom table turn into a VM abort from
*reading input*. So the reader — the single choke point every source text
must pass — samples the VM-global atom table and refuses input once it is
near exhaustion:

- every `:beam_lisp, :atom_check_interval` symbol/keyword tokens
  (default `256`), the reader calls `:erlang.system_info(:atom_count)` and
  compares it against `:erlang.system_info(:atom_limit)`;
- if the fraction `count / limit` reaches `:beam_lisp, :atom_high_water_fraction`
  (default `0.9`), the reader raises `BeamLisp.Reader.AtomLimitError` — a
  **clean, catchable** beam-lisp error that names the offending token, the
  live counts, and the configured ceiling;
- the sampling counter lives in the process dictionary and is reset at the
  start of every read, so nothing leaks between reads and concurrent readers
  in different processes do not interfere.

Configuring it:

```elixir
# mix.exs, config/config.exs, or at runtime:
config :beam_lisp, atom_high_water_fraction: 0.95
config :beam_lisp, atom_check_interval: 512
```

`atom_high_water_fraction` is clamped to `0.0..1.0` and the interval to
`>= 1`, so a misconfiguration fails toward refusing input rather than toward
an abort. The cost is negligible: a handful of process-dictionary operations
per symbol and one `system_info` every 256 tokens. On a 1.5 MB source
(≈40,000 symbol/keyword tokens) the guard measured **no change** in read
time (393 ms with the guard vs 396 ms without, warm, min-of-7 interleaved —
within noise).

## What this guard does and does NOT solve

**It solves:** the failure mode. With the guard, input read into an already
near-full table yields a readable beam-lisp error you can catch and handle,
instead of a crash dump that takes down the whole VM.

**It does NOT solve** — be honest about these:

1. **A single large hostile read.** The guard samples the *absolute* VM-wide
   count, not the *delta* caused by one read. A fresh VM with an empty table
   reading one generated file that would intern a million new names will not
   trip the guard at read time; the compiler's interning would still exhaust
   the table mid-compile. Full protection requires checking at the compiler's
   intern sites too, not just the reader boundary. (The reader cannot track
   this delta — it interns nothing itself.)
2. **Long-running REPLs grow the table monotonically.** Every gensym the
   macro-expander mints, every unique identifier you type or a running
   program generates, is a permanent atom. A REPL that has been up for days
   running macro-heavy code can approach the ceiling on its own — no hostile
   input involved. The guard turns that eventual exhaustion into a clean
   error, but it does not prevent the growth.
3. **It is advisory, not a cap.** Setting the fraction to `1.0` disables the
   guard and restores the raw VM-abort behavior. Nothing in the reader
   prevents the compiler from interning.

The durable fixes for (1) and (2) are real engineering work upstream of the
reader: interning guards in the compiler's `String.to_atom` sites, and
(where the language allows) reusing existing atoms before interning new ones
via `String.to_existing_atom/1`. The reader guard is the boundary's first
line — cheap, always-on, and it turns a catastrophic failure into a
catchable one.
