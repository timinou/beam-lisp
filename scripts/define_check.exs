# scripts/define_check.exs — rungs 3 and 4, against real verse.
#
#   mix run scripts/define_check.exs
#
# The pure rungs are unit-tested (`mix beam_lisp.test test/bl/spell/define_test.bl`).
# These two shell out to a compiler, so they live here rather than in the
# hermetic suite — and they are checked the same way every other claim in this
# project is: by being made to FAIL on input that should fail, not merely to
# pass on input that should pass.
#
# Four cases, in order of what they prove:
#
#   1. the seeded machine COMPILES               (the page we ship is valid)
#   2. it has no ghost selectors                 (rung 4 is quiet when correct)
#   3. a machine with a styled-but-unrendered class is CAUGHT by rung 4
#   4. a machine whose page is malformed is CAUGHT by rung 3
#
# Cases 3 and 4 are the load-bearing ones. Without them, a rung that always
# answered "fine" would pass this script.

alias BeamLisp.Spell

defmodule DefineCheck do
  @out "/tmp/define_check"

  def run do
    File.mkdir_p!(@out)
    Spell.init!(["spell.app", "spell.define", "spell.live"])

    case Spell.Verse.binary() do
      {:error, reason} ->
        IO.puts("\n  SKIPPED — #{reason}\n")
        System.halt(2)

      {:ok, bin} ->
        IO.puts("  spacetime: #{bin}\n")
        results = [
          seed_compiles(),
          seed_has_no_ghosts(),
          ghost_is_caught(),
          broken_is_caught(),
          real_error_still_refused(),
          broken_toolchain_is_not_a_pass()
        ]

        report(results)
    end
  end

  # ── 1 + 2: the machine we ship ───────────────────────────────────────────
  defp seed_compiles do
    {:ok, path} = emit_seed()
    t0 = System.monotonic_time(:millisecond)
    result = Spell.Verse.check(path)
    ms = System.monotonic_time(:millisecond) - t0

    case result do
      {:ok, :compiled} -> pass("rung 3: the seeded machine compiles (#{ms}ms)")
      {:error, diag} -> fail("rung 3: the seeded machine should compile", diag)
    end
  end

  defp seed_has_no_ghosts do
    {:ok, path} = emit_seed()

    case Spell.Verse.ghosts(path) do
      {:ok, %{ghosts: [], unmounted: []}} ->
        pass("rung 4: the seeded machine has no ghost or unmounted selectors")

      {:ok, found} ->
        fail("rung 4: the shipped page should be clean", inspect(found))

      {:error, reason} ->
        fail("rung 4: could not ask verse", reason)
    end
  end

  # ── 3: rung 4 must CATCH a styled class nothing renders ──────────────────
  #
  # The discriminating case. `.phantom-never-rendered` is styled by a definition
  # whose markup renders only `.real`, so verse's emitted CSS names a class its
  # emitted JS never produces. `check --deny-warnings` exits 0 on this — no
  # E-code covers it — which is exactly why rung 4 exists.
  defp ghost_is_caught do
    {:ok, path} = emit_machine(ghost_machine(), "ghost")

    case Spell.Verse.check(path) do
      {:ok, :compiled} ->
        case Spell.Verse.ghosts(path) do
          {:ok, %{ghosts: ghosts}} ->
            if "phantom-never-rendered" in ghosts do
              pass("rung 4: a styled-but-unrendered class IS caught (#{inspect(ghosts)})")
            else
              fail(
                "rung 4: should have caught .phantom-never-rendered",
                "ghosts were #{inspect(ghosts)} — a check that cannot fail is not a check"
              )
            end

          {:error, reason} ->
            fail("rung 4: could not ask verse about the ghost page", reason)
        end

      {:error, diag} ->
        # If the ghost page does not even compile, this case proves nothing
        # about rung 4 — it would be passing for the wrong reason.
        fail("rung 4: the ghost fixture must COMPILE for the case to mean anything", diag)
    end
  end

  # ── 4: rung 3 must CATCH a page verse refuses ────────────────────────────
  defp broken_is_caught do
    path = Path.join(@out, "broken.st")

    File.write!(path, """
    /* Deliberately invalid: a template reference nothing declares (E0916). */
    @import "stdlib/macros/data-kind"
    @import "stdlib/macros/each"

    @data inline $items : [];

    .list {
      @each($items, as: $i, template: &no-such-template)
    }
    """)

    case Spell.Verse.check(path) do
      {:error, diag} ->
        pass("rung 3: an invalid page IS refused (#{first_line(diag)})")

      {:ok, :compiled} ->
        fail(
          "rung 3: verse accepted a page referencing an undeclared template",
          "a rung that cannot refuse is not a rung"
        )
    end
  end

  # ── 5: the W0201 exemption must not swallow real diagnostics ────────────
  #
  # Rung 3 exempts W0201 for the three sources verse cannot trace through
  # `@on`/`@view` (draft, status, send). An exemption is a hole unless it is
  # shown to be exactly the size claimed, so this page carries BOTH an exempt
  # warning (an unused `$draft`) and a real error. The rung must still refuse
  # it, and the refusal must not mention the exempt warning.
  defp real_error_still_refused do
    path = Path.join(@out, "warn_and_error.st")

    File.write!(path, """
    /* An unused $draft (W0201, exempt) AND a malformed directive (E0946, a real
       error).

       The malformed `@each` is deliberate: a reference to an UNDECLARED
       template (`&no-such-template`) turned out not to be an error here at all
       — verse accepted it with only the W0201 — so using it would have made
       this case pass while proving nothing about the exemption. Checked before
       relying on it. */
    @import "stdlib/macros/data-kind"
    @import "stdlib/macros/each"

    @data inline $draft : "";
    @data inline $items : [];

    .list {
      @each($items, as: $i, template: &row)
    }
    """)

    case Spell.Verse.check(path) do
      {:error, diag} ->
        if String.contains?(diag, "'draft'") do
          fail("rung 3: the exemption should drop the draft W0201 from the report", diag)
        else
          pass("rung 3: a real error is still refused alongside an exempt warning")
        end

      {:ok, :compiled} ->
        fail(
          "rung 3: the W0201 exemption swallowed a real error",
          "an exemption that hides a malformed directive is a hole, not a filter"
        )
    end
  end

  # ── 6: a broken toolchain must never read as a clean page ───────────────
  #
  # The worst failure available to a checker. An earlier version of rung 3
  # filtered the output for problem lines and passed when it found none — so a
  # compiler that crashed, or was missing entirely, printed no `error[` marker
  # and the rung reported success. Every later rung, and the whole loop, would
  # then be validating nothing while reporting green.
  defp broken_toolchain_is_not_a_pass do
    fake = Path.join(@out, "fake_spacetime")
    File.write!(fake, "#!/bin/sh\necho 'panic: boom'\nexit 101\n")
    File.chmod!(fake, 0o755)

    result =
      with_env("VERSE_BIN", fake, fn ->
        Spell.Verse.check(Path.join(@out, "seed.st"))
      end)

    case result do
      {:error, reason} ->
        if String.contains?(reason, "without emitting a diagnostic") do
          pass("rung 3: a crashing compiler is refused, not accepted")
        else
          pass("rung 3: a crashing compiler is refused (#{first_line(reason)})")
        end

      {:ok, :compiled} ->
        fail(
          "rung 3: a crashing compiler read as a clean page",
          "exit 101 with no diagnostic must never be {:ok, :compiled}"
        )
    end
  end

  defp with_env(key, value, fun) do
    previous = System.get_env(key)
    System.put_env(key, value)

    try do
      fun.()
    after
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end
  end

  # ── fixtures ─────────────────────────────────────────────────────────────
  # The machines below are built from beam-lisp SOURCE deliberately: they are
  # this script's fixtures, and a fixture written in the language it exercises
  # is the point (see `ghost_machine/0` — the ghost page must be one the tool
  # would actually accept, expressed the way a definition is).
  #
  # What changed in PLAN-027 W1 is where the value goes afterwards:
  # `Page.emit/3` takes the machine VALUE, so nothing has to be bound to a
  # global var for the emitter to find it. That global was how two writers of
  # one name came to exist.
  defp emit_seed do
    machine =
      bl("""
      (spell.live/seeded (spell.machine/empty-machine)
                         spell.seed/contract-term
                         spell.seed/view-term)
      """)

    Spell.Page.emit(machine, Path.join(@out, "seed.st"))
  end

  defp emit_machine(setup_src, label) do
    Spell.Page.emit(bl(setup_src), Path.join(@out, "#{label}.st"))
  end

  # A machine built THROUGH the define tool, not by hand: the ghost page must be
  # one the tool would actually accept, or the case tests a state the loop
  # cannot reach.
  defp ghost_machine do
    """
      (get (spell.define/define
             (spell.machine/register-contract (spell.machine/empty-machine)
               (spell.contract/parse :ghost-live {}
                 (list (quote (assign @items :list)))))
             {:kind "view" :name "ghosty" :rationale "a rule matching nothing"
              :templates [{:name "row" :html "<li class='real'>{@i.text}</li>"}]
              :style [{:selector ".real" :rules {:color "#fff"}}
                      {:selector ".phantom-never-rendered" :rules {:color "#f00"}}]
              :binds [{:selector ".real" :each {:binding "items" :as "i" :template "row"}}]})
           :machine)
    """
  end

  # ── plumbing ─────────────────────────────────────────────────────────────
  defp bl(src), do: BeamLisp.Compiler.eval_string(src)
  defp pass(what), do: {:pass, what}
  defp fail(what, why), do: {:fail, what, why}
  defp first_line(s), do: s |> String.split("\n") |> Enum.find(&(String.trim(&1) != "")) |> String.trim()

  defp report(results) do
    Enum.each(results, fn
      {:pass, what} -> IO.puts("  ✓ #{what}")
      {:fail, what, why} -> IO.puts("  ✗ #{what}\n      #{String.replace(why, "\n", "\n      ")}")
    end)

    failed = Enum.count(results, &match?({:fail, _, _}, &1))
    IO.puts("\n  #{length(results) - failed}/#{length(results)} passed")
    if failed > 0, do: System.halt(1)
  end
end

DefineCheck.run()
