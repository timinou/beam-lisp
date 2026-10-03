# Working in this repo

## Every `bl` command is a whole BEAM

A cold `bl run`, `bl test`, `bl eval` or `bl self-build` starts its own VM. That
VM loads the language and its ~50 dependency apps before it touches your file.
Measured on this host (2026-10-02): a cold `bl run` of `(println 1)` peaks at
**150–160 MB RSS**, and `bl test` / `bl self-build` runs sit at 200–400 MB. A
VM that stays up grows from there, because it keeps its eval modules, its var
table and its caches.

So memory is `number of bl processes × ~150 MB`, not the size of any one job.
This host has 47 GB of RAM and is routinely deep in swap. Four agents each
running a test loop is enough to push it there.

### Before you launch bl processes

1. **Look first.** `scripts/bl-mem` lists every beam-lisp VM with RSS, swap,
   peak, age and the command. Swap counts: a VM that has been idle for days
   shows a few MB of RSS and gigabytes of swap, so read the `TOTAL` column.
   Rows marked `!` are over an hour old and own 512 MB or more.
2. **Run one file, not the suite.** `bl test path/to/one_test.bl`. A full
   `bl test` is a long job; give it a ceiling (below).
3. **Do not launch many cold VMs in a loop or in parallel.** Each is ~150 MB
   and also pays the startup cost again. One `bl test a.bl b.bl c.bl` is one VM
   and one startup for three files.
4. **Cap anything big or long.** Run it under a memory limit so a runaway
   cannot take the machine with it:

   ```sh
   systemd-run --user --collect --wait --working-directory=$PWD \
     --property=MemoryMax=8G --property=MemorySwapMax=2G \
     ./bin/bl test test/bl/some_test.bl
   ```

5. **Stop what you start.** A `bl serve`, `bl watch`, `bl mcp` or daemon you
   launched for a check is yours to stop when the check is done. They do not
   exit by themselves, and one forgotten for three days held 7 GB of swap.

### A warm VM is not yet a fix

Re-using one warm VM instead of starting a cold one per command is the design
direction (PLAN-158, realms). Today it does **not** cover this:

- the realm work lives on the `realm` branch and is not in `main`;
- the launcher's default transport is *attach*: it uses a warm VM only if one
  is already running and never starts one;
- one VM per user and build (the step that makes many projects share a VM) is
  not built.

Until all three change, assume every command costs its own VM.

## Which bl

In a checkout run `./bin/bl`, not the installed drop on `PATH`; see
`docs/dev/which-bl.md`. A change under `priv/boot/` rebuilds the whole toolchain
on the next run. That takes several minutes and a few hundred MB, so batch boot
edits and run the build under a cap.
