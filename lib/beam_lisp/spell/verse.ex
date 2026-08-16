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
    # Only ask cargo when the root actually exists: `System.cmd` with a bad `cd`
    # prints a raw `spawn: Could not cd to …` to stderr, which lands on top of
    # this module's own, actionable "no spacetime binary — build it with …"
    # message and buries it.
    from_cargo =
      if File.dir?(verse_root()) do
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
      else
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

  ## W0201 is exempted NARROWLY, and why the narrowness matters

  `--deny-warnings` turns every warning into a failure, and verse emits
  `W0201 "data source X is defined but never used"` for signals that ARE used
  by `@on` handlers and `@view` arms — constructs its usage analysis does not
  trace. Measured on the page this project ships and screenshots: four W0201s,
  for `draft`, `status`, `send` and `fx`.

  Three of those four are false positives: the composer writes `$draft`, the
  button fires `$send`, the indicator dispatches on `$status` — each verified
  in the emitted JS.

  The fourth was NOT. `$fx` is the token stream; the contract pushes
  `@token`/`@failed` and the server sends them, but no bind consumes the
  stream, so streamed tokens arrive in the browser and render nothing. A
  blanket "drop every W0201" hid a real defect behind an exemption written for
  a different one — exactly the way an exemption becomes a hole. (Found by a
  reviewer, confirmed against the emitted bundle, recorded as a defect in
  PLAN-025 for the wave that renders streamed tokens.)

  So the exemption is keyed to the *kinds* of source verse cannot trace — the
  ones a page consumes through `@on`/`@view` — and a `@data stream` is not one
  of them: nothing but a bind can consume a stream, so verse is RIGHT about it
  and the warning must be heard.

  If verse's usage analysis learns about `@on`/`@view`, this filter deletes and
  nothing else changes.
  """
  def check(st_path) do
    with {:ok, bin} <- binary() do
      case verse_cmd(bin, ["check", "--deny-warnings", Path.expand(st_path)]) do
        {_out, 0} ->
          {:ok, :compiled}

        {out, code} ->
          # A non-zero exit is a REFUSAL by default. Only one thing may downgrade
          # it: output whose every diagnostic is an exempt W0201.
          #
          # The first version of this filtered the output for problem lines and
          # passed when none were found, which inverted the default — a crashing
          # or missing compiler prints no `error[` marker, so
          # `VERSE_BIN=/usr/bin/false` and a binary printing `panic: boom` both
          # returned {:ok, :compiled}. A broken toolchain reading as a clean page
          # is the worst failure available to a checker: every later rung, and
          # the whole loop, would then be validating nothing while reporting
          # success. Caught by a reviewer; reproduced before fixing.
          case classify(out) do
            :only_exempt_warnings -> {:ok, :compiled}
            {:problems, lines} -> {:error, Enum.join(lines, "\n")}
            :unrecognised -> {:error, unrecognised_message(code, out)}
          end
      end
    end
  end

  @doc """
  What a non-zero `check` run actually said.

      :only_exempt_warnings   diagnostics found, ALL of them exempt
      {:problems, lines}      at least one real error or non-exempt warning
      :unrecognised           no diagnostics at all: a crash, a usage message,
                              a missing file. NEVER a pass.

  Public because it is the POLICY, and policy is the half of this module that
  can be checked without a compiler. The runner needs cargo and a subprocess;
  this needs a string. Separating them is what lets the rule that decides
  whether a model's definition lives or dies run on every `mix test`.
  """
  def classify(output) do
    diagnostics =
      output
      |> String.split("\n")
      |> Enum.filter(&(String.contains?(&1, "error[") or String.contains?(&1, "warning[")))
      |> Enum.map(&String.trim/1)

    problems = Enum.reject(diagnostics, &exempt?/1)

    cond do
      problems != [] -> {:problems, problems}
      diagnostics != [] -> :only_exempt_warnings
      true -> :unrecognised
    end
  end

  # A W0201 for a source verse genuinely cannot trace — and ONLY those.
  #
  # `@on` and `@view` consume a source without verse's analysis seeing it, so a
  # W0201 naming a signal a page writes or dispatches on is noise. A stream has
  # no such blind spot: nothing but a bind can consume one, so an unused stream
  # is a real finding and stays a refusal. Sources are matched by NAME because
  # that is all the warning line carries; the list is deliberately explicit
  # rather than a wildcard, so a new unused source has to be looked at by a
  # human before it joins.
  #
  # `partial` and `error` joined after exactly that look. Both are consumed by
  # a `@view` arm — the streaming bubble and the failure notice — which is the
  # same blind spot `status` sits in, and both were verified in the emitted
  # bundle before being listed: `@view $partial { _ => &streaming; }` and
  # `@view $error { _ => &error; }` are present in the `.st`, and the browser
  # renders both (streamed tokens appear word by word; a provider failure shows
  # its reason). Neither is a stream, so verse's one real signal here is
  # untouched: `fx` stays OUT of this list and keeps refusing the page.
  @exempt_sources ~w(draft status send partial error)

  @doc """
  Is this diagnostic line a W0201 for a source verse genuinely cannot trace?

  Public for the same reason as `classify/1`: the exemption list is a judgment
  about which warnings are noise, and a judgment deserves a test. `fx` staying
  OUT of it is an assertion, not an omission.
  """
  def exempt?(line) do
    String.contains?(line, "W0201") and
      Enum.any?(@exempt_sources, &String.contains?(line, "'#{&1}'"))
  end

  defp unrecognised_message(code, out) do
    detail = out |> String.trim() |> String.slice(0, 400)

    "spacetime check exited #{code} without emitting a diagnostic " <>
      "(a crash, a usage error or a missing file — NOT a clean page): " <>
      if(detail == "", do: "no output", else: detail)
  end

  @doc """
  Rung 4 — selectors that name nothing the page renders.

  Two joins over the compiler's own output, both `… minus rendered`:

    * STYLED but not rendered — a rule matching no element. Silent: CSS does
      not create DOM.
    * BOUND but not rendered — behaviour attached to an element that does not
      exist. Worse than silent: the definition looks complete, compiles, styles
      correctly, and does nothing.

  The second was found by the demo. A model-proposed `clock` view bound
  `.clock`, no markup rendered a `.clock` element, and the definition passed
  rungs 1–4 while the browser showed no clock — the page correct about
  everything except existing.

  ## The bind join takes its LEFT side from our own selectors

  Scanning the bundle for every `querySelector` was the obvious implementation
  and it is wrong: the emitted JS contains verse's RUNTIME as well as our page,
  so the seeded machine reported `.ad-form`, `.ad-preview-frame` and friends —
  library code we did not write and cannot judge. `bound_selectors` is passed in
  by the caller, who knows which selectors the machine declared; only those are
  joined against what the compiler rendered.

  `{:ok, %{ghosts: [], unmounted: []}}` when clean; an error when verse could
  not be asked — never conflated with a clean page.
  """
  def ghosts(st_path, bound_selectors \\ []) do
    with {:ok, bin} <- binary(),
         {:ok, css, js} <- emit_layers(bin, st_path) do
      rendered = rendered_classes(js)

      {:ok,
       %{
         ghosts: styled_classes(css) -- rendered,
         unmounted: class_tokens(bound_selectors) -- rendered
       }}
    end
  end

  @doc """
  The single-class tokens among a list of selectors.

  Conservative on purpose: `.log` yields `log`, while `.a .b`, `.a[x]`, `#id`
  and `main` yield nothing. A compound or attribute selector may legitimately
  match host markup the machine never emitted — `&shell` is mounted by the host
  page — so the check fires only where attribution is certain.
  """
  def class_tokens(selectors) do
    selectors
    |> Enum.flat_map(fn sel ->
      case Regex.run(~r/\A\.([A-Za-z_][-\w]*)\z/, String.trim(to_string(sel))) do
        [_, cls] -> [cls]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
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
    # Every run of non-brace text immediately before a `{` is a selector — the
    # scan is deliberately NOT anchored to the start of a line.
    #
    # It was (`~r/^\s*([^{}\n][^{}]*)\{/m`), and that agreed with verse only
    # because verse currently pretty-prints one rule per line. On a minified
    # bundle — or on any rule following a `}` on the same line — the anchor
    # matches nothing, `styled_classes` answers `[]`, and the ghost join
    # becomes `[] -- rendered`, which is EMPTY. Rung 4 would then pass every
    # definition while looking exactly as green as it does now: a check that
    # cannot fail, disabled by a downstream formatting change nobody here would
    # think to re-test. Found by a unit test written against a one-line
    # stylesheet.
    #
    # The unanchored form also reaches selectors nested inside an at-rule
    # (`@media (…) { .a { … } }`), which the anchored one dropped.
    Regex.scan(~r/([^{}]*)\{/, css)
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
  def verify(st_path, bound_selectors \\ []) do
    case check(st_path) do
      {:error, diag} ->
        {:error, %{rung: :compile, reason: diag}}

      {:ok, :compiled} ->
        case ghosts(st_path, bound_selectors) do
          {:ok, %{ghosts: [], unmounted: []}} ->
            {:ok, %{ghosts: [], unmounted: []}}

          {:ok, %{ghosts: [], unmounted: unmounted}} ->
            {:error,
             %{
               rung: :ghosts,
               reason:
                 "bind selector(s) no template renders: " <>
                   Enum.map_join(unmounted, ", ", &".#{&1}") <>
                   " — behaviour attached to an element that does not exist " <>
                   "compiles, styles correctly and does nothing"
             }}

          {:ok, %{ghosts: ghosts}} ->
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
