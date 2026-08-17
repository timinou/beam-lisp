defmodule BeamLisp.Spell.LoopTest do
  @moduledoc """
  The define ladder, driven without a model.

  `scripts/demo.exs` proves this in a browser and is the acceptance artefact.
  What it cannot be is a unit test: it needs verse, a bundle, an HTTP server and
  headless Chrome, so it runs on demand and not in `mix test`. This suite takes
  the same three proposals and asserts the same verdicts at the level below —
  which is what makes PLAN-027's refactor safe, because a rung that stops
  refusing will fail here in seconds rather than in a demo nobody ran.

  ## What each proposal is FOR

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

  alias BeamLisp.Spell.Live

  @out Path.join(System.tmp_dir!(), "spell-loop-test")

  setup_all do
    File.rm_rf(@out)
    File.mkdir_p!(@out)

    # `publish: false` — the loop is exercised, the bundle is not. Building it
    # costs a `spacetime build` per accepted definition and proves nothing this
    # suite claims; `scripts/demo.exs` owns that half.
    {:ok, pid} = Live.start_link(out: @out, publish: false, name: __MODULE__.Loop)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(@out)
    end)

    %{loop: __MODULE__.Loop}
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp clock_proposal do
    %{
      "kind" => "view",
      "name" => "clock",
      "rationale" => "render each message with a timestamped clock face",
      "templates" => [%{"name" => "clockface", "html" => "<div class='clock'>{@m.text}</div>"}],
      "style" => [
        %{"selector" => ".clock", "rules" => %{"font-size" => "0.75rem", "opacity" => "0.6"}}
      ],
      "binds" => [
        %{
          "selector" => ".log",
          "each" => %{"binding" => "messages", "as" => "m", "template" => "clockface"}
        }
      ]
    }
  end

  defp ghost_proposal do
    %{
      "kind" => "view",
      "name" => "ghosty",
      "rationale" => "deliberately styles a class no template renders",
      "templates" => [%{"name" => "real", "html" => "<i class='real'>{@m.text}</i>"}],
      "style" => [
        %{"selector" => ".real", "rules" => %{"color" => "#fff"}},
        %{"selector" => ".phantom-never-rendered", "rules" => %{"color" => "#f00"}}
      ],
      "binds" => [
        %{
          "selector" => ".real",
          "each" => %{"binding" => "messages", "as" => "m", "template" => "real"}
        }
      ]
    }
  end

  defp unmounted_proposal do
    %{
      "kind" => "view",
      "name" => "floating",
      "rationale" => "binds a selector no template renders",
      "templates" => [%{"name" => "drift", "html" => "<i class='drift'>{@m.text}</i>"}],
      "style" => [%{"selector" => ".drift", "rules" => %{"color" => "#fff"}}],
      "binds" => [
        %{
          "selector" => ".nowhere",
          "each" => %{"binding" => "messages", "as" => "m", "template" => "drift"}
        }
      ]
    }
  end

  # ── rungs 1–2: no compiler needed ──────────────────────────────────────────

  describe "rung 1 — the proposal's own shape" do
    test "a proposal with no rationale is refused, and says which fields are missing", %{
      loop: loop
    } do
      # Rationale is what renders in the chat: a change nobody can read is a
      # change nobody can review. It is required for that reason, not for
      # tidiness.
      verdict = Live.define(loop, %{"kind" => "view", "name" => "x"})

      assert verdict.status == :rejected
      assert verdict.rung == :schema or verdict.rung == :proposal
      assert to_string(verdict.reason) =~ "rationale"
    end

    test "an unknown kind is refused rather than guessed", %{loop: loop} do
      verdict = Live.define(loop, %{"kind" => "gizmo", "name" => "x", "rationale" => "r"})
      assert verdict.status == :rejected
    end
  end

  describe "the data boundary" do
    test "a key that is not a plain name is refused BEFORE anything is evaluated", %{loop: loop} do
      # The recorded P0. This exact key closed the call and opened a new form,
      # so `(def pwned 99)` evaluated before any rung ran — a model could have
      # reached anything the BEAM can reach.
      #
      # This test outlives its mechanism on purpose: PLAN-027 W1 replaces the
      # printer with a value-level boundary, and the payload must still be
      # refused afterwards. If it ever passes, the boundary regressed however
      # it is implemented.
      hostile = %{
        "kind \"view\"}))\n(def pwned 99)\n(def z {:kind" => "view",
        "name" => "x",
        "rationale" => "r"
      }

      verdict = Live.define(loop, hostile)

      assert verdict.status == :rejected
      assert BeamLisp.Env.fetch("user", "pwned") == :error,
             "a model-supplied map key was EVALUATED — the boundary is open"
    end

    test "a struct is refused rather than printed", %{loop: loop} do
      verdict =
        Live.define(loop, %{
          "kind" => "view",
          "name" => "x",
          "rationale" => "r",
          "when" => ~D[2026-08-16]
        })

      assert verdict.status == :rejected
    end
  end

  # ── rungs 3–4: the compiler's own verdict ──────────────────────────────────

  describe "rungs 3–4 — what verse says" do
    @describetag :verse

    test "a correct view is ACCEPTED and joins the machine", %{loop: loop} do
      verdict = Live.define(loop, clock_proposal())

      assert verdict.status == :ok,
             "the clock view was refused at #{inspect(verdict[:rung])}: #{inspect(verdict[:reason])}"

      assert "clock" in Live.state(loop).machine["views"]
    end

    @tag :publishes
    test "a view that renames the page template away from `shell` reports a STALE publish",
         %{} do
      # The live incident. Asked to improve the chat view, a model produced a
      # correct proposal that named the page template `&chat` instead of
      # `&shell` — a reasonable name, and nothing had told it otherwise.
      #
      # Every rung accepted it, and before the fix the story ended there: the
      # machine took the definition, the bundle was rebuilt, `report.json`
      # announced a new version, and the browser kept rendering the PREVIOUS
      # page — because `machine-shell` returned nil, so the host module (which
      # renders the shell SERVER-side) was never regenerated. A machine that
      # grows while the page cannot change, with no error anywhere.
      #
      # Note what is asserted and what is NOT. The proposal is structurally
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

      {:ok, loop} = Live.start_link(out: out, name: nil)

      shell_renamed = %{
        "kind" => "view",
        "name" => "chat-view",
        "rationale" => "a page template under any other name",
        "templates" => [
          %{"name" => "chat", "html" => "<main class=\"chat\"><div class=\"log\" data-log></div></main>"},
          %{"name" => "message", "params" => ["m"], "html" => "<p class=\"bubble\">{@m.text}</p>"}
        ],
        "binds" => [
          %{
            "selector" => ".log",
            "each" => %{"binding" => "messages", "as" => "m", "template" => "message"}
          }
        ]
      }

      verdict = Live.define(loop, shell_renamed)

      assert verdict.status == :published_stale,
             "a definition that leaves the page unhostable was reported as a " <>
               "clean success: #{inspect(verdict)}"

      assert verdict.rung == :publish

      assert to_string(inspect(verdict.reason)) =~ "shell",
             "the report must NAME what is missing, or the model cannot act " <>
               "on it: #{inspect(verdict.reason)}"

      GenServer.stop(loop)
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
      before = Live.state(loop).version

      assert Live.define(loop, clock_proposal()).status == :ok

      assert Live.state(loop).version == before,
             "the version moved with no publish behind it — a polling browser " <>
               "would reload onto an unchanged bundle"
    end

    test "a styled class nothing renders is REFUSED at the ghosts rung", %{loop: loop} do
      verdict = Live.define(loop, ghost_proposal())

      assert verdict.status == :rejected
      assert verdict.rung == :ghosts
      assert to_string(verdict.reason) =~ "phantom-never-rendered"
    end

    test "a bind on a selector nothing renders is REFUSED, for its own reason", %{loop: loop} do
      verdict = Live.define(loop, unmounted_proposal())

      assert verdict.status == :rejected
      assert verdict.rung == :ghosts

      assert to_string(verdict.reason) =~ "bind selector",
             "the unmounted join reported the styled join's message — " <>
               "deleting one join would leave the other's test green"
    end

    test "a refusal leaves the machine EXACTLY as it was", %{loop: loop} do
      before = Live.state(loop)

      Live.define(loop, ghost_proposal())
      Live.define(loop, unmounted_proposal())

      after_refusals = Live.state(loop)

      assert after_refusals.machine == before.machine,
             "a refused definition left state behind — every later proposal " <>
               "would then be checked against a machine no author approved"

      assert after_refusals.version == before.version,
             "a refusal bumped the version, so the browser reloaded for nothing"
    end
  end

  # ── the transcript ─────────────────────────────────────────────────────────

  describe "the repl state" do
    test "state/1 answers with a version, a transcript and a machine report", %{loop: loop} do
      state = Live.state(loop)

      assert is_integer(state.version)
      assert is_list(state.transcript)
      assert is_map(state.machine)

      for key <- ~w(views contracts assigns events errors warnings) do
        assert Map.has_key?(state.machine, key), "the report has no #{key}"
      end
    end
  end
end
