defmodule BeamLisp.Spell.LoopTest do
  @moduledoc """
  The run ladder, driven without a model.

  `scripts/demo.exs` proves this in a browser and is the acceptance artefact.
  What it cannot be is a unit test: it needs verse, a bundle, an HTTP server and
  headless Chrome, so it runs on demand and not in `mix test`. This suite takes
  the same three definitions and asserts the same verdicts at the level below —
  which is what makes PLAN-027's refactor safe, because a rung that stops
  refusing will fail here in seconds rather than in a demo nobody ran.

  ## What each definition is FOR

  Three fixtures, and each one exists because it fails a DIFFERENT way:

    * `clock`     — the accepted case. Mounts into `.log`, which `&shell`
                    renders. It first bound `.clock`, its own template's class,
                    and passed all four rungs while a browser showed nothing:
                    a bind selector must match an element that ALREADY exists.
    * `ghosty`    — styles `.phantom-never-rendered`. Rungs 1–3 pass it; verse
                    compiles it happily because no E-code covers a rule
                    matching nothing. Only rung 4's styled join sees it.
    * `floating`  — every styled class renders, and the BIND targets `.nowhere`.
                    Isolates rung 4's other join. Without it, deleting the
                    unmounted join entirely would leave the ghost case green —
                    a check that cannot fail.

  ## The two halves, and why they are tagged apart

  Rungs 1–2 reason about terms and need nothing. Rungs 3–4 shell out to
  `spacetime`, cost ~2s each and need a built binary. Both matter; only the
  first can be assumed available, so the second is tagged `:verse` and skipped
  with a REASON when the binary is missing — never silently passed, which would
  make a missing toolchain read as a clean ladder.
  """

  use ExUnit.Case, async: false
  use BeamLisp.SpellCase

  alias BeamLisp.Spell.Loop

  @out Path.join(System.tmp_dir!(), "spell-loop-test")

  setup_all do
    File.rm_rf(@out)
    File.mkdir_p!(@out)

    # `publish: false` — the loop is exercised, the bundle is not. Building it
    # costs a `spacetime build` per accepted definition and proves nothing this
    # suite claims; `scripts/demo.exs` owns that half.
    {:ok, pid} = Loop.start_link(out: @out, publish: false, name: __MODULE__.Loop)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(@out)
    end)

    %{loop: __MODULE__.Loop}
  end

  # —— fixtures ——————————————————————————————————————————————————————————————

  defp clock_src do
    "(defview clock (markup (template &clock [\$m] [:div {:class \"clock\"} @m.text])) (style [\".clock\" {:font-size \"0.75rem\" :opacity \"0.6\"}]) (binds [\".log\" (st/each @messages :as @m :template &clock)]))"
  end

  defp ghost_src do
    "(defview ghosty (markup (template &real [\$m] [:i {:class \"real\"} @m.text])) (style [\".real\" {:color \"#fff\"}] [\".phantom-never-rendered\" {:color \"#f00\"}]) (binds [\".real\" (st/each @messages :as @m :template &real)]))"
  end

  defp unmounted_src do
    "(defview floating (markup (template &drift [\$m] [:i {:class \"drift\"} @m.text])) (style [\".drift\" {:color \"#fff\"}]) (binds [\".nowhere\" (st/each @messages :as @m :template &drift)]))"
  end

  # —— rungs 1–2: no compiler needed ————————————————————————————————————————

  describe "rung 1 — the source's own shape" do
    test "source that does not parse is refused", %{loop: loop} do
      verdict = Loop.run(loop, "(defview clock (markup", "incomplete source")

      assert verdict.status == :rejected
      assert verdict.rung == :schema
    end

    test "a junk head is refused at the schema rung", %{loop: loop} do
      verdict = Loop.run(loop, "(println 1)", "not a defview or defcontract")

      assert verdict.status == :rejected
      assert verdict.rung == :schema
    end

    test "a def is a code head — it walks the fence, not the refusal", %{loop: loop} do
      # W4: `(def pwned 99)` is CODE, not junk. Accepted via the fence rung
      # into spell.vars — this is the tool growing the image, by design.
      verdict = Loop.run(loop, "(def w4-pwned-marker 99)", "a value def")

      assert verdict.status == :ok
      assert verdict[:kind] == "code"
    end

    test "a compile-time head is refused at the schema rung", %{loop: loop} do
      verdict = Loop.run(loop, "(defmacro pwned [x] x)", "macro attempt")

      assert verdict.status == :rejected
      assert verdict.rung == :schema
    end
  end

  describe "the data boundary" do
    test "the source is READ, never evaluated, so injected code cannot run", %{loop: loop} do
      # The recorded P0. This test outlives its mechanism on purpose: the
      # source is READ not evaluated, and the definition must still be refused
      # afterwards. If it ever passes, the boundary regressed.
      #
      # Malformed source that would execute code IF the boundary evaluated it:
      # the string itself closes a form and opens a new one with `(def pwned 99)`.
      # But since the source is only read as text and then parsed, `pwned` never
      # gets defined.
      hostile = "kind \"view\"))\n(def pwned 99)\n(def z {:kind"

      verdict = Loop.run(loop, hostile, "r")

      assert verdict.status == :rejected
      assert BeamLisp.Env.fetch("user", "pwned") == :error,
             "a model-supplied source was EVALUATED — the boundary is open"
    end
  end

  # —— rungs 3–4: the compiler's own verdict —————————————————————————————————

  describe "rungs 3–4 — what verse says" do
    @describetag :verse

    test "a correct view is ACCEPTED and joins the machine", %{loop: loop} do
      verdict = Loop.run(loop, clock_src(), "render each message with a timestamped clock face")

      assert verdict.status == :ok,
             "the clock view was refused at #{inspect(verdict[:rung])}: #{inspect(verdict[:reason])}"

      assert "clock" in Loop.state(loop).machine["views"]
    end

    @tag :publishes
    test "a view that renames the page template away from `shell` reports a STALE publish",
         %{} do
      # The live incident. Asked to improve the chat view, a model produced a
      # correct definition that named the page template `&chat` instead of
      # `&shell` — a reasonable name, and nothing had told it otherwise.
      #
      # Every rung accepted it, and before the fix the story ended there: the
      # machine took the definition, the bundle was rebuilt, `report.json`
      # announced a new version, and the browser kept rendering the PREVIOUS
      # page — because `machine-shell` returned nil, so the host module (which
      # renders the shell SERVER-side) was never regenerated. A machine that
      # grows while the page cannot change, with no error anywhere.
      #
      # Note what is asserted and what is NOT. The definition is structurally
      # sound — no orphan binding, no unhandled fire — so the RUNGS are right
      # to pass it, and an errors-level rule refusing it would also refuse the
      # partial machines `spell.machine.test` builds (tried; 16 failures). The
      # defect is not that the machine is invalid, it is that the result cannot
      # be SERVED, which is a publish-time fact and belongs in the publish
      # verdict.
      #
      # So this pins `:published_stale` with a reason naming the shell: the
      # model is told its definition landed but the page did not, in words it
      # can act on. `publish: false` cannot see this — hence its own loop.
      out = Path.join(System.tmp_dir!(), "noshell-#{System.unique_integer([:positive])}")
      gen = Path.join(out, "gen")
      File.mkdir_p!(gen)
      prev = Application.get_env(:beam_lisp, :spell_gen_dir)
      Application.put_env(:beam_lisp, :spell_gen_dir, gen)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:beam_lisp, :spell_gen_dir, prev),
          else: Application.delete_env(:beam_lisp, :spell_gen_dir)

        File.rm_rf(out)
      end)

      {:ok, loop} = Loop.start_link(out: out, name: nil)

      shell_renamed =
        "(defview chat-view (markup (template &chat [] [:main {:class \"chat\"} [:div {:class \"log\" :data-log true}]]) (template &message [m] [:p {:class \"bubble\"} @m.text])) (style [\".bubble\" {:margin \"0\"}]) (binds [\".log\" (st/each @messages :as @m :template &message)]))"

      verdict = Loop.run(loop, shell_renamed, "a page template under any other name")

      assert verdict.status == :published_stale,
             "a definition that leaves the page unhostable was reported as a " <>
               "clean success: #{inspect(verdict)}"

      assert verdict.rung == :publish

      assert to_string(inspect(verdict.reason)) =~ "shell",
             "the report must NAME what is missing, or the model cannot act " <>
               "on it: #{inspect(verdict.reason)}"

      GenServer.stop(loop)
    end

    test "an accepted definition REPORTS what the machine noticed", %{loop: loop} do
      # Warnings mean INCOMPLETE, and incomplete definitions are accepted on
      # purpose — a machine that refuses them cannot be grown one definition at
      # a time. The defect was reporting acceptance as bare success, so the
      # findings lived only in a report nobody reads aloud.
      #
      # Observed live (`!tasks/artifacts/PLAN-027-repl-after.png`): a model
      # redefined chat-view, kept the shell's `{@partial}` and `{@error}` holes
      # and dropped the `@view` binds consuming them. Three `unrendered-assign`
      # warnings were raised, the verdict said "✓ defined view", and the page
      # rendered the literal strings `{@partial}` and `{@error}`. The model
      # could have fixed it that same turn had anyone told it.
      #
      # Asserted through `Loop.run/3`'s verdict rather than the bubble text
      # so it holds for every caller of the ladder, and the assertion names the
      # ASSIGN — a warning the model cannot act on is the same silence in a
      # different font.
      # A view that renders NEITHER `@partial` nor `@error` — exactly what the
      # live model produced. The seed renders both, so the seed's own warnings
      # would not exercise this; the finding has to be caused, not borrowed.
      forgetful =
        "(defview chat-view (markup (template &shell [] [:main {:class \"chat\"} [:div {:class \"log\" :data-log true}]]) (template &message [m] [:p {:class \"bubble\"} @m.text])) (style [\".bubble\" {:margin \"0\"}]) (binds [\".log\" (st/each @messages :as @m :template &message)]))"

      verdict = Loop.run(loop, forgetful, "drop the binds that consume @partial and @error")

      assert verdict.status == :ok,
             "an incomplete definition must still be ACCEPTED — refusing it " <>
               "makes the machine ungrowable: #{inspect(verdict)}"

      warnings = verdict.report["warnings"] || verdict.report[:warnings] || []

      kinds =
        Enum.map(warnings, fn w ->
          to_string(Map.get(w, :kind) || Map.get(w, "kind"))
        end)

      assert "unrendered-assign" in kinds,
             "the finding that produced two literal holes on a served page is " <>
               "missing from the verdict: #{inspect(kinds)}"

      assigns =
        warnings
        |> Enum.map(fn w -> to_string(Map.get(w, :assign) || Map.get(w, "assign") || "") end)

      assert "partial" in assigns and "error" in assigns,
             "the warning must NAME the assign the model dropped, or it cannot " <>
               "act on it: #{inspect(assigns)}"
    end

    test "the version counts PUBLISHES, not acceptances", %{loop: loop} do
      # Worth pinning because it is the browser's reload trigger and the two
      # readings differ. `version` is what `report.json` carries and the page
      # polls; bumping it on an acceptance that was never published would
      # reload a browser onto a bundle that had not changed, and bumping it
      # only on a *changed machine* would miss a rebuild after a manual edit.
      #
      # Under `publish: false` — this suite's mode — the machine grows and the
      # version must NOT move. `scripts/demo.exs` runs the publishing half and
      # asserts the opposite there, which is where that claim belongs.
      before = Loop.state(loop).version

      assert Loop.run(loop, clock_src(), "render each message with a clock").status == :ok

      assert Loop.state(loop).version == before,
             "the version moved with no publish behind it — a polling browser " <>
               "would reload onto an unchanged bundle"
    end

    test "a styled class nothing renders is REFUSED at the ghosts rung", %{loop: loop} do
      verdict = Loop.run(loop, ghost_src(), "deliberately styles a class no template renders")

      assert verdict.status == :rejected
      assert verdict.rung == :ghosts
      assert to_string(verdict.reason) =~ "phantom-never-rendered"
    end

    test "a bind on a selector nothing renders is REFUSED, for its own reason", %{loop: loop} do
      verdict = Loop.run(loop, unmounted_src(), "binds a selector no template renders")

      assert verdict.status == :rejected
      assert verdict.rung == :ghosts

      assert to_string(verdict.reason) =~ "bind selector",
             "the unmounted join reported the styled join's message — " <>
               "deleting one join would leave the other's test green"
    end

    test "a refusal leaves the machine EXACTLY as it was", %{loop: loop} do
      before = Loop.state(loop)

      Loop.run(loop, ghost_src(), "ghosty")
      Loop.run(loop, unmounted_src(), "floating")

      after_refusals = Loop.state(loop)

      assert after_refusals.machine == before.machine,
             "a refused definition left state behind — every later proposal " <>
               "would then be checked against a machine no author approved"

      assert after_refusals.version == before.version,
             "a refusal bumped the version, so the browser reloaded for nothing"
    end
  end

  # —— the transcript ———————————————————————————————————————————————————————

  describe "the repl state" do
    test "state/1 answers with a version, a transcript and a machine report", %{loop: loop} do
      state = Loop.state(loop)

      assert is_integer(state.version)
      assert is_list(state.transcript)
      assert is_map(state.machine)

      for key <- ~w(views contracts assigns events errors warnings) do
        assert Map.has_key?(state.machine, key), "the report has no #{key}"
      end
    end
  end
end
