defmodule BeamLisp.Spell.Verse do
  @moduledoc """
  Rungs 3 and 4 of the define ladder: the checks only the COMPILER can answer.

  Rungs 1–2 (`spell.define`) reason about terms. They can tell you a view binds
  a name no contract declares, because both facts are in the machine. They
  cannot tell you whether the page verse produces actually renders an element
  matching a styled selector — that answer lives downstream of an emitter, a
  macro expander and a code generator we do not own.

      3. compile — `spacetime check --deny-warnings` on the emitted page
      4. ghosts  — styled selectors that no rendered markup matches

  ## Why rung 4 is not a regex over our own templates

  `spell.machine/rendered-classes` exists and is deliberately the WEAK path: it
  scans the HTML strings we generated, so it agrees with our emitter by
  construction. It would have reported `.log` as rendered while the page had no
  `.log` at all — the exact failure this project already shipped once.

  Rung 4 asks verse instead: `inspect --layer emit` returns the final CSS and
  the final JS, and template markup survives into `registerTemplate` calls in
  that JS. Styled minus rendered is then a join over the compiler's own output,
  which is independent ground truth. PLAN-023 verified it discriminates: on a
  page styling `.real`, `.ghost-never-exists` and `.also-missing__elem`, only
  `.real` appears in the emitted JS — while `check --deny-warnings` exits 0,
  because no E-code covers this.

  ## Speed is a correctness property here

  Every `define` call pays these rungs. `cargo run` re-checks the build graph on
  each invocation and costs seconds; a released binary costs milliseconds. The
  loop is interactive — a model retrying three times behind a 30s check is a
  loop nobody runs, and a check nobody runs protects nothing. So the release
  binary is preferred and its absence is reported as a fixable condition rather
  than silently falling back to something slow.
  """

  @default_verse Path.expand("~/code/ora/verse")

  @doc "Where verse lives (`VERSE_ROOT`, else the conventional checkout path)."
  def verse_root, do: System.get_env("VERSE_ROOT") || @default_verse

  @doc """
  The spacetime binary to run: `{:ok, path}` or `{:error, reason}`.

  Prefers a released binary. `VERSE_BIN` overrides for an installed one. No
  `cargo run` fallback: a fallback that is 100× slower is not the same
  affordance, and discovering that only through a sluggish loop is worse than
  being told.

  The target directory is ASKED of cargo rather than assumed to be
  `<root>/target`: this machine sets a shared `CARGO_TARGET_DIR`
  (`~/.cache/cargo-target`), so a successful `cargo build --release` left
  nothing at the conventional path and the check reported "no binary" while a
  perfectly good one existed. Guessing another project's layout is how a tool
  ends up lying about work that was already done.
  """
  def binary do
    candidates =
      [System.get_env("VERSE_BIN")] ++
        Enum.map(target_dirs(), &Path.join(&1, "release/spacetime"))

    candidates = Enum.reject(candidates, &is_nil/1)

    case Enum.find(candidates, &executable?/1) do
      nil ->
        {:error,
         "no spacetime binary (looked at #{Enum.join(candidates, ", ")}). " <>
           "Build it once: cd #{verse_root()} && cargo build --release --bin spacetime"}

      path ->
        {:ok, path}
    end
  end

  # Cargo's own answer first, the conventional layout second. `cargo metadata`
  # costs ~50ms and is cached by the caller for the session; being right about
  # where the binary is beats being fast about looking in the wrong place.
  defp target_dirs do
    from_cargo =
      case System.cmd("cargo", ["metadata", "--format-version", "1", "--no-deps"],
             cd: verse_root(),
             stderr_to_stdout: false
           ) do
        {out, 0} ->
          case JSON.decode!(out) do
            %{"target_directory" => dir} -> [dir]
            _ -> []
          end

        _ ->
          []
      end

    env =
      case System.get_env("CARGO_TARGET_DIR") do
        nil -> []
        "" -> []
        d -> [d]
      end

    Enum.uniq(env ++ from_cargo ++ [Path.join(verse_root(), "target")])
  rescue
    _ -> [Path.join(verse_root(), "target")]
  end

  defp executable?(path), do: File.regular?(path) and File.stat!(path).mode |> Bitwise.band(0o111) != 0

  # Every spacetime invocation runs with cwd = the verse root.
  #
  # The stdlib registry (`stdlib/macros/*.st`) is resolved RELATIVE TO CWD, so
  # the same document that prints perfectly from the verse checkout fails from
  # anywhere else with `unknown macro "data-subscribe"` — a message that reads
  # like the document is malformed rather than like the tool cannot find its own
  # standard library. Diagnosed by running a KNOWN-GOOD document (the one
  # `seed.bl` emits and this project screenshots) and watching it fail
  # identically: that is what proved the fault was in the invocation, not in the
  # merged document I had just written.
  defp verse_cmd(bin, args, opts \\ []) do
    System.cmd(bin, args, Keyword.merge([cd: verse_root(), stderr_to_stdout: true], opts))
  end

  @doc """
  Rung 3 — compile the page and return the compiler's own verdict.

  `{:ok, :compiled}` | `{:error, diagnostic}`. The diagnostic is verse's text,
  verbatim: it is written for a human staring at a page, which is exactly the
  audience on the other end of a rejected proposal, and paraphrasing it would
  only lose the line numbers.

  ## W0201 is not counted, and why that is not a loophole

  `--deny-warnings` turns every warning into a failure, and verse emits
  `W0201 "data source X is defined but never used"` for signals that ARE used
  — by `@on` handlers and `@view` arms, which its usage analysis does not
  currently trace. Measured: the page this project ships, serves and
  screenshots (`/tmp/chat-serve/page.st`, emitted by the pipeline in
  `serve_chat.sh`) produces exactly four of them, for `draft`, `status`, `send`
  and `fx` — all four demonstrably wired, since the composer writes `$draft`,
  the button fires `$send`, the indicator dispatches on `$status`, and tokens
  arrive over `$fx`.

  A rung that refuses working software gets switched off, and then it protects
  nothing. So W0201 specifically is dropped and every OTHER warning still
  fails the rung. The narrow exemption is named here rather than achieved by
  removing `--deny-warnings`, because dropping the flag would silently exempt
  every future warning class too.

  If verse's usage analysis learns about `@on`/`@view`, this filter deletes and
  nothing else changes.
  """
  def check(st_path) do
    with {:ok, bin} <- binary() do
      case verse_cmd(bin, ["check", "--deny-warnings", Path.expand(st_path)]) do
        {_out, 0} ->
          {:ok, :compiled}

        {out, _} ->
          case real_problems(out) do
            [] -> {:ok, :compiled}
            lines -> {:error, Enum.join(lines, "\n")}
          end
      end
    end
  end

  # Diagnostic lines that are not the known false positive. Errors are always
  # kept; only W0201 warnings are dropped, and only they.
  defp real_problems(output) do
    output
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.contains?(line, "error[") or
        (String.contains?(line, "warning[") and not String.contains?(line, "W0201"))
    end)
    |> Enum.map(&String.trim/1)
  end

  @doc """
  Rung 4 — styled selectors that nothing renders.

  `{:ok, []}` when clean, `{:ok, ghosts}` when the page styles classes the
  compiled markup never produces, `{:error, reason}` when verse could not be
  asked. Note the distinction: an empty ghost list is a PASS, while an error is
  "this rung did not run" — collapsing them would let a broken toolchain read
  as a clean page.
  """
  def ghosts(st_path) do
    with {:ok, bin} <- binary(),
         {:ok, css, js} <- emit_layers(bin, st_path) do
      {:ok, styled_classes(css) -- rendered_classes(js)}
    end
  end

  defp emit_layers(bin, st_path) do
    # stdout and stderr are kept SEPARATE deliberately: any chatter merged into
    # stdout makes the JSON unparseable, and the resulting failure reads as a
    # verse bug rather than a plumbing mistake (the lesson machine_check.exs
    # records about cargo's build output).
    case verse_cmd(bin, ["inspect", "--layer", "emit", "--format", "json", Path.expand(st_path)],
           stderr_to_stdout: false
         ) do
      {out, 0} ->
        # OTP 28's built-in `JSON`, not Jason: Jason reaches this project only as
        # a transitive dev dependency of tidewave, so depending on it here would
        # make a load-bearing check evaporate the moment that dev tool is
        # dropped — in :prod, or in a checkout that skips dev deps.
        case json_decode(out) do
          {:ok, %{"css" => %{"content" => css}, "js" => %{"content" => js}}} ->
            {:ok, css, js}

          # A JSON.decode! result is a plain Elixir map and can never be one of
          # beam-lisp's struct types; the guard only separates an object from a
          # decoded array or scalar so Map.keys/1 below is safe.
          # is_map-ok: any decoded JSON object, structs are not reachable here
          {:ok, other} when is_map(other) ->
            {:error, "unexpected inspect shape: #{inspect(Map.keys(other))}"}

          {:error, reason} ->
            {:error, "inspect did not return JSON: #{reason}"}
        end

      {out, code} ->
        {:error, "spacetime inspect failed (exit #{code}): #{String.trim(out)}"}
    end
  end

  defp json_decode(text) do
    {:ok, JSON.decode!(text)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Class tokens named by CSS selectors.

  Deliberately conservative: it takes the class tokens out of each selector, so
  `.bubble[data-role='user']` contributes `bubble`. The goal is to catch a class
  nothing renders, not to reimplement selector matching — and a conservative
  extractor errs toward silence, which is the safe direction for a check that
  can block a definition.
  """
  def styled_classes(css) do
    Regex.scan(~r/^\s*([^{}\n][^{}]*)\{/m, css)
    |> Enum.map(fn [_, sel] -> sel end)
    |> Enum.flat_map(fn sel ->
      Regex.scan(~r/\.([A-Za-z_][-\w]*)/, sel) |> Enum.map(fn [_, c] -> c end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Class tokens the compiler actually put into rendered markup."
  def rendered_classes(js) do
    Regex.scan(~r/class=\\?['"]([^'"\\]*)/, js)
    |> Enum.flat_map(fn [_, c] -> String.split(c, ~r/\s+/, trim: true) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Print an emitted EDN document as `.st`, via verse's own printer.

  Exposed because `BeamLisp.Spell.Page` needs it and the cwd discipline above
  must not be duplicated: a second call site that forgets it fails with a
  message about an unknown macro.
  """
  def print_st(edn_path) do
    with {:ok, bin} <- binary() do
      case verse_cmd(bin, ["st", Path.expand(edn_path)]) do
        {out, 0} -> {:ok, String.trim(out)}
        {out, code} -> {:error, "spacetime st failed (exit #{code}): #{String.trim(out)}"}
      end
    end
  end

  @doc """
  Both verse rungs over one emitted page.

  `{:ok, %{ghosts: []}}` | `{:error, %{rung: :compile | :ghosts, reason: …}}`.
  Rung 3 runs first and short-circuits: a page that does not compile has no
  meaningful emit layer to join against, and reporting a ghost-selector list
  derived from a failed compile would be reporting noise as a finding.
  """
  def verify(st_path) do
    case check(st_path) do
      {:error, diag} ->
        {:error, %{rung: :compile, reason: diag}}

      {:ok, :compiled} ->
        case ghosts(st_path) do
          {:ok, []} ->
            {:ok, %{ghosts: []}}

          {:ok, ghosts} ->
            {:error,
             %{
               rung: :ghosts,
               reason:
                 "styled selector(s) no template renders: " <>
                   Enum.map_join(ghosts, ", ", &".#{&1}") <>
                   " — CSS does not create DOM, so a rule matching nothing is silent"
             }}

          {:error, reason} ->
            {:error, %{rung: :ghosts, reason: reason}}
        end
    end
  end
end
