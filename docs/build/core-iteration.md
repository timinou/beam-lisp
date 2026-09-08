# Working on the compiler

Use the normal commands while editing:

```sh
mix compile
mix test test/beam_lisp/aot_reproducible_test.exs
```

The committed bootstrap seed supplies the compiler needed to build current source. Ordinary development builds do not regenerate that seed. Regenerate it at the commit-time bootstrap gate:

```sh
mix run priv/bootstrap/gen_manifest.exs
```

## One compiler generation at a time

Boot sources change the compiler used by every namespace. The build compiles them **serially, in dependency order**, before compiling library dependency waves in parallel. A boot failure stops the library phase. Boot sources must not depend on ordinary library sources.

When the seed supplies an older build program, the Mix task loads the current build source while retaining the seed compiler needed to compile it. Core body binaries become available before namespace shims start forwarding calls to them.

## What invalidates the build?

A boot-source edit changes the toolchain key and requires rebuilding its consumers. This includes ordinary functions in `core`: macros and compiler helpers may call them while generating code. Function signatures alone cannot capture that dependency.

A source with unchanged inputs and toolchain key is a no-op. The content-addressed cache can reuse the same compiled inputs across build directories. Cache reuse does not replace freshness checks.

## Cache housekeeping

Cache generations live under the user cache directory, or `BEAM_LISP_AOT_CACHE_DIR`. Successful stores trigger a bounded cleanup, at most once an hour per VM. The current key is always retained. Defaults retain eight generations, expire generations older than thirty days, and remove at most four per sweep.

Configure retention in application configuration:

```elixir
config :beam_lisp, :aot_cache_gc,
  keep_generations: 8,
  max_age_days: 30,
  max_delete: 4,
  interval_ms: 3_600_000
```

Only real directories named as SHA-256 keys are eligible. Symlinks and unrelated files are left alone. Rebuilding a cache-linked beam replaces its local file, preserving the cached bytes.

To verify a build without cache reuse:

```sh
BEAM_LISP_AOT_CACHE=off mix compile.beam_lisp --force
```
