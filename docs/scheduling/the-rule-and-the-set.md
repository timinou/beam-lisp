# The rule and the set — recurrence, and why it is not a cron string

*Companion to `the-clock-and-the-wheel.md`. That document decided when a thing
fires. This one decides **what "every last Friday" is** — and answers the
question the plan left open at its §6.4: "recurrence arithmetic is a library,
not a decision."*

---

## 0. Verdict in one paragraph

Cron is a **string** and RRULE is a **string**, and both are *unreasoning*: you
can parse them, print them, and fire them, and that is the whole of what they
afford. Our time model already has the right shape — a temporal value is a
bounded half-open interval at a resolution, with **Allen's 13 relations**, set
algebra, an `expand`, and a **z3 bridge** (`priv/lib/datom/time.bl`, verified
below). So recurrence should not be a parser bolted on: it should be **a rule
that produces a SET of intervals**, whose exceptions and additions are the set
algebra we already ship, whose *preview* is computed by the same function the
wheel fires from, and which can therefore be **reasoned about** — "can these two
schedules ever collide?" — instead of merely executed. RRULE stays, as the
**interchange** format we read and write so we interoperate with iCalendar and
everyone else. It is not the user surface, because a string cannot be composed,
cannot be explained, and cannot be proved.

---

## 1. Prior art, and exactly what each one cannot say

The interesting question about a recurrence notation is not how it *reads*. It
is what it **cannot express** — because that is where the silent wrongness
lives: a schedule that quietly does not fire, or fires twice, and nobody finds
out until the backup did not happen.

### 1.1 Vixie cron (and cronie, and every job runner shaped like it)

Five fields — minute, hour, day-of-month, month, day-of-week — with `*`,
literals, ranges, steps and lists. **There is no ordinal weekday**, so "the last
Friday" can only be approximated by intersecting "days 24-31" with "Friday" —
and that hack is wrong, measurably:

```
the cron hack `0 0 24-31 * 5` fires only when the last Friday is day >= 24
months 2015-2030 where it MISSES: 5 of 192
   2018-02-23   2019-02-22   2024-02-23   2029-02-23   2030-02-22
the last Friday's day-of-month ranges over 22 … 31
```

Every miss is a February — a month short enough that the last Friday lands early
— and **no day-range repairs it**: widen to `22-31` and the months whose last
Friday *is* the 31st fire twice (the 24th is a Friday too). The set of possible
days is ten values wide, the notation can name ten, and there is no range whose
*intersection with Friday* is exactly the last one. Cron cannot say it. (Cron
also has a one-minute floor and no timezone; the clock is the machine's.)

### 1.2 Quartz — `L`, `W`, `#`

Quartz escapes the field model with three letters: `6L` is the last Friday,
`6#3` the third, `W` the nearest weekday. It works, and it keeps the model
*field-shaped*: a field, not a set. Nothing composes: "the last Friday, except
in December, and also every Monday" is three triggers or none, and no arithmetic
relates them to each other or to a maintenance window.

### 1.3 Oban — measured against its own documentation

Oban is a job *queue*, not a clock, and it is honest about it: periodic work goes
through `Oban.Cron`, and the docs (`hexdocs.pm/oban/periodic_jobs.html`) say
precisely this:

* five fields, with `*`, literals, `*/15` steps, `0-5` ranges, `1,3,5` lists, and
  `JAN`/`MON` names;
* aliases `@hourly @daily @midnight @weekly @monthly @yearly @annually @reboot`;
* **"Resolution Limit: Cron scheduling has a one-minute resolution at minimum"**;
* `:timezone` **is** supported — one place Oban is ahead of us, and worth
  copying;
* and a recipe titled **"More Flexible Than CRON Scheduling"**, whose content is:
  compute the next instant yourself and insert a one-shot job.

So the answer to "how does Oban fix 'the last Friday'" is: **it doesn't, and it
cannot.** Oban's non-cron recurrence is *self-rescheduling* — the worker inserts
its own successor — which moves the recurrence arithmetic out of the framework
and into the application, where it gets written again per job, by hand, without
tests. That is a fork of the same need into every caller, which is exactly the
shape this repo deletes.

Note what is *not* the lesson here: Oban is not badly built. It is built on the
one thing everyone has — a string — and a string is where the composition stops.

### 1.4 RFC 5545 RRULE — the real standard

The iCalendar recurrence rule is the only widely-implemented notation that
actually expresses the cases: `FREQ` (SECONDLY…YEARLY), `INTERVAL`, `COUNT`,
`UNTIL`, `WKST`, the `BY*` selectors (SECOND, MINUTE, HOUR, DAY, MONTHDAY,
YEARDAY, WEEKNO, MONTH, SETPOS), plus sidecar **`RDATE`** (add these instants)
and **`EXDATE`** (except these) and `VTIMEZONE`.

```
FREQ=MONTHLY;BYDAY=-1FR;BYHOUR=9;BYMINUTE=30     the last Friday at 09:30
```

Two properties matter more than the surface:

* **`BYDAY` carries an ordinal** — `-1FR`, `2TU` — which is the thing cron
  structurally lacks;
* **the recurrence is a SET**, and `RDATE`/`EXDATE` are set *union* and set
  *difference*. The standard's authors reached for exactly the algebra
  `datom.time` already has.

Its cost: the syntax is a string (parseable, printable, not composable), partial
support is the norm rather than the exception (Salesforce's own scheduler,
`joyous`, `dateutil`, `rrule.js`, the Rust `rrule` crate all document gaps), and
the semantics are subtler than they look — for each `FREQ`, each `BY*` either
**expands** the set or **limits** it, and `BYSETPOS` then selects from the
result. Get that table wrong (RFC 5545 §3.3.10) and you invent a calendar that
is plausible, periodic, and off by a week. Time is UTC unless a `VTIMEZONE`
travels with the rule.

### 1.5 ISO 8601-2 / EDTF, and RFC 7529

ISO 8601-2 formalises archaeological and uncertain time: masks (`156X`), sets,
open intervals, and **repeat intervals** (`R5/2026-01-01/P1M`). EDTF Level 2 has
"one of" sets and the `X` mask. This is the family `datom.time` already reads —
`(expand (read-iso8601 "#time\"156X\""))` yields ten year-intervals — which means
the gap between "an uncertain date" and "a recurrence" is smaller here than
anywhere else: both are *a set of intervals selected from a coarser one*.
RFC 7529 (`RSCALE`) extends RRULE to non-Gregorian calendars.

### 1.6 Tempo — the same thesis as ours, taken further (and the actual prior art)

`ex_tempo` (hex, by Kip Cole) is an Elixir library whose README opens with
"time as interval, not instant" — which is `datom.time`'s model exactly: one
type, bounded half-open `[from, to)`, a resolution, Allen's relations, set
algebra, cross-zone and cross-calendar comparison. It goes further, and reading
it is the cheapest way to see where this road ends:

* a first-class **`IntervalSet`** (sorted, non-overlapping, coalesced) with
  sweep-line `union`/`intersect`/`difference`/`complement` — ours returns *one*
  interval, so ours cannot hold a set;
* **`Tempo.Network`** — a web of partially-known intervals solved by constraint
  propagation (the **ChronoLog** scheme), with a plain-English trace for every
  bound;
* **`Tempo.Schedule`** — tasks, durations, dependencies → earliest/latest and the
  critical path;
* **`Tempo.explain/1`** — a structured, tagged explanation (`:headline`, `:span`,
  `:qualification`, …) with renderers for terminal and HTML;
* full **RFC 5545 RRULE** import *and* a documented **shared AST for ISO 8601 and
  RRULE** — one internal representation for both;
* time zones via Elixir's `Calendar.TimeZoneDatabase` (carry a `:tz`; don't
  bundle one).

Its own prior-art list is the honest map of the field, and worth carrying as
ours: **Allen's interval algebra (1983)**; Jensen/Dyreson/Tansel's *Consensus
Glossary of Temporal Database Concepts* (1998), which gives us the **chronon** —
an indivisible time unit whose resolution determines how a value is read; Eric
Evans' "Exploring Time"; **Postgres 14+ multirange** (sorted, coalesced interval
sets, sweep-line operations); **`calendar_interval`**; ISO 8601-2/EDTF; RFC
5545/7529; **IXDTF** (`…[Europe/Paris][u-ca=hebrew]`).

### 1.7 The solver lineage

* **ChronoLog** and constraint propagation (Tempo.Network) — tighten a web of
  known intervals;
* **OR-Tools CP-SAT / Timefold / MiniZinc** — the industrial answer to
  *scheduling* (resources, durations, precedence, optimisation);
* **SMT encodings of Allen's algebra** — the academic route, and the one this
  repo already took: `datom.time` proves an overlap verdict and satisfiability of
  ordering constraints through **z3**.

Nobody in that list answers *"can these two recurrences ever collide?"* — the
question a scheduler's operator actually has.

---

## 2. What we already have, and what is genuinely missing

Verified by reading `priv/lib/datom/time.bl`:

| capability | there? |
|---|---|
| interval at a resolution, half-open, `from`/`to`/`width` | ✅ |
| Allen's 13 relations, `overlaps?`/`meets?`/`precedes?`/`contains?`/`subset?`/`disjoint?` | ✅ |
| `intersect`, `union`, `subtract` — **returning one interval (or two)** | ✅ (too narrow) |
| `expand` — a coarse/masked interval → its members; `count-set` | ✅ |
| EDTF masks via `read-iso8601` (`156X` → a decade) | ✅ |
| z3: `overlap-verdict` (three-valued, proven) and `consistent?` (ordering constraints satisfiable) | ✅ |
| a **set** type (an `IntervalSet`, sweep-line, coalesced) | ❌ |
| a rule → occurrences generator, and RRULE parse/emit | ❌ (being built: `datom.recur`) |
| time zones / DST | ❌ (`sched`: "Time zones are not implemented yet") |

So the missing piece is not a language. It is: **a rule that yields a set**, a
**set that can hold the result**, and **two questions a set can be asked** (does
it collide; does it fit).

---

## 3. The mini-DSL: a rule reads as the sentence, and emits the standard

The user surface is Lisp, composed from the algebra that exists:

```clojure
;; the rule, read as the sentence a human would say
(recur :month (on :friday :last) (at 9 30))     ; the last Friday at 09:30
(recur :week 2 (on :monday) (at 8 0))           ; every second Monday at 08:00
(recur :day (at 6 0))                           ; daily at 06:00
(recur :year (in :march) (on :sunday :last))    ; the DST Sunday, some places
(recur :month (on :day 31) {:clamp :last})      ; the 31st, clamped where short

;; composition IS the set algebra, and that is the whole point
(∪ (recur :day (at 8 0)) (recur :day (at 18 0)))         ; twice a day
(∖ (recur :day (at 6 0)) holidays)                       ; except holidays
(∩ (recur :week (on :monday)) (interval :year 2026))     ; only this year
(take 5 (recur :month (on :friday :last)))
(until (recur :day (at 6 0)) ~o"2026-12-31")
```

Four design commitments, each of which is a thing cron and RRULE cannot do:

**(a) A rule is data, so it can be *shown*, *stored*, and *reasoned about*.**
`(recur :month (on :friday :last) (at 9 30))` is a map. The pane renders the next
eight occurrences *from it*; the store keeps it as a fact; z3 encodes it. A
cron string can only be re-parsed.

**(b) The preview is the same function that fires.** `(next rule n)` is
`proc.sched`'s own `next` — not a second implementation written for the
dashboard. The bug we must never ship is a pane that promises a fire the wheel
does not perform (or vice versa), and the only structural defence is one
function.

**(c) `(explain rule)` — and `(why rule instant)`.** Following
`Tempo.explain/1`'s shape: a tagged, structured explanation, so the terminal and
the page render one value; plus, for any instant, **which selector admitted
it**. "It ran because the rule is `:month (on :friday :last)` and this is
2026-09-25" is the answer to the only question an operator asks at 03:00. cron
gives back a string; RRULE gives back `BYDAY=-1FR` and no reason.

**(d) The questions a set can be asked — this is the *wow*.**

```clojure
(collides? (recur :day (at 2 0)) backup)          ; → a proof, or a witness
(fits? nightly-window (recur :day (at 3 0)))      ; is there room, always?
(free between busy)                               ; set difference — already exists
(critical-path tasks)                             ; needs durations, not just times
```

Tempo's `Network` solves partially-known *data* (when did this stratum end?);
OR-Tools solves *resource* scheduling with an optimiser. Nothing in the field
answers "can these two recurrence rules ever land on the same minute" — and that
is precisely the question this repo is already equipped to answer, because
`datom.time/consistent?` and `overlap-verdict` **already encode intervals as
integers for z3**. The DSL is the thing that makes the encoding *reachable*: a
rule becomes a finite set of integer bounds over a window, and the question
becomes `(check (and …))`.

The honest limit belongs in the docstring, not in the marketing: z3 answers over
a **bounded window** (`(collides? a b {:within (interval :year 2026)})`). An
unbounded claim needs the recurrence *arithmetic* (a theorem about BYDAY and
modular arithmetic), which is a different project — and saying so is what keeps
`(collides? …)` from becoming a lie of omission.

---

## 4. Time zones, and the two instants that do not exist

The gap we must name before anyone relies on this: `datom.time` has no zone, and
`sched` refuses `:tz` with "Time zones are not implemented yet: give a `daily`
hour in the…". Oban *has* `:timezone`, Tempo rides `Calendar.TimeZoneDatabase` —
so this is a real deficit, not a style choice.

Two instants per year make it unavoidable, and **both must be decided, not
defaulted**:

* **spring forward**: 02:30 does not exist on that day. Choose — *skip* the day
  (the occurrence is dropped), *shift* to 03:00, or *fire at the zone offset
  before the jump*. cron silently runs it at 03:30 (the kernel's timer fires
  late); that is a decision nobody wrote down.
* **fall back**: 01:30 happens twice. Fire **once** (the wheel keys on the
  occurrence, and both map to one instant) — firing twice is the bug the
  idempotency key exists to catch.

A rule therefore *carries* its zone (`{:tz "Europe/Berlin"}`) and is evaluated
against a zone database; the interval arithmetic is unchanged, because a day
containing a jump is simply a 23- or 25-hour interval, and `datom.time` is
already interval-native. That is the payoff of the model: DST is not a special
case, it is arithmetic on widths.

---

## 5. Where the pieces live

| piece | home | state |
|---|---|---|
| the rule model, `occurrences`, `next`/`prev`, RRULE parse/emit, `explain` | `priv/lib/datom/recur.bl` (new) | being built |
| the interval algebra it stands on | `priv/lib/datom/time.bl` | exists |
| z3 access | `priv/std/z3pool.bl` (`check`, `command`, `with-solver`) | exists |
| the wheel that fires | `priv/std/proc/sched.bl` (`:every` / `:daily` / `:at`; `:cron` and `:tz` refused *by name*) | exists, gains a `:rule` |
| the preview + `explain` in the UI | `priv/std/vm/inspect.bl`, `vm/http.bl` | exists (rows), gains a rule row |
| an `IntervalSet` that can hold a rule's result | `datom.time` | **missing** |

---

## 6. Roadmap (replacing §6.4's "a library, not a decision")

* **R1 — the rule as data.** `datom.recur`: the rule value, validation that
  refuses an unknown key *by name*, `occurrences`/`next`/`prev`, and RRULE
  parse/emit for the parts that matter (FREQ, INTERVAL, COUNT, UNTIL, WKST,
  BYDAY with ordinals, BYMONTHDAY, BYMONTH, BYHOUR, BYMINUTE, BYSETPOS).
  Conformance: RFC 5545 §3.8.5.3's own examples, plus the last-Friday month that
  cron gets wrong.
* **R2 — the set.** An `IntervalSet` in the time model (coalesced, sweep-line),
  because `union`/`subtract` returning one interval is the reason exceptions
  cannot be expressed today. `RDATE`/`EXDATE` fall out of it.
* **R3 — the wheel accepts a rule.** `(sched (rule …) id fn)`, and the pane's
  preview calls the wheel's own `next`.
* **R4 — the questions.** `(collides? a b {:within w})`, `(fits? window rule)`,
  and `(explain rule)` / `(why rule instant)`.
* **R5 — zones.** A rule carries a `:tz`; the DST policy of §4 is written down
  and tested on a real jump (the zone database is a dependency, not a bundle).
* **R6 — the interchange test.** Read an `.ics` RRULE and run it; emit ours and
  read it back. Tempo is the *conformance oracle* we can differential-test
  against, which is a far stronger check than our own expectations.

---

## 7. Decisions settled with the user (2026-09-18)

| # | question | decision |
|---|---|---|
| 1 | Is a recurrence a cron string, an RRULE, or a rule-set? | **A rule-set**, with RRULE as **interchange** so we interoperate. A string cannot be composed, explained, or proved — and the repo's own ethic (a macro where a clause would do is a fork) applies to notations too. |
| 2 | Does Oban solve this? | **No, and by construction**: Oban's periodic work *is* cron (five fields, one-minute floor), and its documented answer to anything else is "insert the next job yourself" — recurrence arithmetic pushed into every application. Oban's `:timezone` is the part worth copying. |
| 3 | Where does the "wow" live — the notation, or the reasoning? | **The reasoning.** Tempo already ships a rule language and a solver for *partially-known* time; OR-Tools/Timefold solve industrial scheduling. Nobody answers "can these two rules ever collide?" — and we can, because our time model is already intervals encoded for z3. |
| 4 | What is the honest limit? | **Bounded windows.** z3 answers over a window; an unbounded claim needs recurrence arithmetic as a theorem. State it, do not paper over it. |

---

## Sources

* `priv/lib/datom/time.bl` (read in full — the audit in §2 is from the source,
  not from memory)
* `priv/std/proc/sched.bl` (`KNOWN-FREQS`, the `:cron`/`:tz` refusals)
* `hexdocs.pm/oban/periodic_jobs.html` — "Cron Expressions", "Cron Extensions",
  "Caveats & Guidelines" (the one-minute resolution limit; `:timezone`)
* `hexdocs.pm/ex_tempo/readme.html` — Tempo's model, `Network`, `Schedule`,
  `explain`, its RFC 5545 conformance guide, and **its own prior-art list**
* RFC 5545 §3.3.10 (RRULE), §3.8.5 (RDATE/EXRULE/EXDATE); RFC 7529 (RSCALE);
  ISO 8601-2 / EDTF
* Allen, J. F. (1983), *Maintaining knowledge about temporal intervals*;
  Jensen/Dyreson/Tansel (1998), *The Consensus Glossary of Temporal Database
  Concepts* (the chronon); Postgres 14 multirange types
* Measured here: the 5-of-192-month miss rate of the cron hack, and the
  22…31 range of the last Friday's day-of-month (`python3`, 2015–2030, in this
  commit's message trail)
