# The console

`bl ui` should answer one question: **what is running, and is it healthy?** The
old page answered a different one — *what is this one project's daemon holding?* —
and put it nine panes deep.

## What exists (the first slice)

`/machine` on the session's HTTP server, and `/api/vms`:

- the headline: `1 VM, 1 realm.`
- **Needs attention**, only when there is something: a fact and its fix command;
- the VM table: id, role, build, state, up, memory, a Stop action;
- under each VM, one tinted row per realm with its path and routes as links;
- one sentence and the command, when nothing is running.

It renders the same rows as `bl vm`. Verified live: a real daemon appeared in the
table, the Stop button for a *second* VM stopped that process and removed its
files, and the page's own VM had no button.

## Information architecture (target)

```
/                 the machine: attention, then the VM tree
/vm/<id>          one VM: its realms, memory, log tail, actions
/realm/<id>       today's dashboard, demoted: tasks, index, schedules, members
/routes           the name table, with the gateway's state at the top
/api              the reference that used to be a "Transport" table on the page
```

| view | answers |
|---|---|
| `/` | what is running? what needs me? |
| `/vm/<id>` | why is this one big? what is it holding? |
| `/realm/<id>` | what is my project doing? |
| `/routes` | what names exist and who answers them? |

## Behaviour

| feature | rule |
|---|---|
| status | a **word and a mark** (`● up`, `▲ up, unregistered`, `✕ gone`), never colour alone |
| actions | per row; destructive ones state the effect before it happens |
| confirm | none for a single stop; a summary for `stop all` ("stops 3 VMs, frees ports 4000, 4012") |
| feedback | an `aria-live` region; a button disables while its request runs |
| keyboard | focus is visible; `j`/`k` move, `enter` opens, `s` stops *(planned)* |
| live | server-sent events or polling, diffing rows in place — **no layout shift** *(planned)* |
| empty | one sentence, one command |
| narrow screens | the build column hides; nothing scrolls sideways |
| motion | none that moves layout; `prefers-reduced-motion` is honoured |

## Design rules

The page is held to [impeccable](https://impeccable.style)'s rules and to a few of
its own. Each is checkable in the source or by a tool.

| rule | how it is held |
|---|---|
| **one scale each** for type and spacing, named once | CSS custom properties `--t-*` and `--s*`; every later rule reads them |
| **contrast ≥ 4.5:1** | computed for both themes: lowest body-text ratio **6.48:1** (muted text on a tinted row, light); highest 16.68:1 |
| **light and dark** from one set of tokens | `prefers-color-scheme` swaps the token values, not the rules |
| **no card inside a card** | the page has a table and a tinted row; no boxes |
| **no side-stripe accent, no gradient, no glow, no shadow** | tested: the CSS contains none of `gradient`, `box-shadow`, `border-left` |
| **no kicker above the title** | the `h1` stands alone |
| **line length ≤ ~75ch** | `p{max-width:62ch}` |
| **don't animate layout** | no `transition:width|all`; the only transition is `opacity` on a button, and only when motion is allowed |
| **icons carry no meaning alone** | the marks `● ▲ ✕` always sit beside a word |
| **an empty state is a sentence, not a grid of empty panels** | tested |

**Measured.** `impeccable detect` on the old dashboard: 8 findings (7 warnings,
1 advisory). On `/machine`: **0 findings**, exit 0.

**Caveats.** The detector says itself that a clean scan is not a design review —
it covers 61 source and browser rules, and hierarchy and clarity still need a
person (`/impeccable critique`). It needs Node and a browser, so it can be an
optional check, never a gate in `bl test`. The tests that *can* run everywhere
check the rules that are checkable from the CSS text.

## What the page deliberately does not do

- Show **a health score**. Each concern states a fact and a command.
- Offer **start**. Starting a VM is a project's decision (`bl daemon start` in the
  project, or auto-start); the machine view is about what already runs.
- Replace the REPL, the catalog or the schedules page; those stay per-realm.
- Embed the API reference. That moved off the page.

## Hosting

The slice mounts the console on a session VM's server. The target hosts it in the
**gateway**: it is machine-wide, outlives every VM, sees the `Host` header, and
can read every token — which a *stop* needs. The cost is that the gateway becomes
load-bearing; it should stay small and start lazily.
