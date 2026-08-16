defmodule BeamLisp.Spell.VersePolicyTest do
  @moduledoc """
  What the compiler's output MEANS — decided here, without running it.

  `BeamLisp.Spell.Verse` is two things wearing one name: a runner (find the
  binary, shell out, respect cwd) and a policy (which warnings are noise, what
  a ghost selector is, when a non-zero exit is a refusal). Only the runner
  needs a subprocess. This suite covers the policy against recorded output, so
  the rules that decide whether a model's definition lives or dies are checked
  on every `mix test` rather than only when someone has cargo installed.

  ## The defect this suite exists to keep dead

  `check/1`'s first version filtered the output for problem lines and passed
  when it found none — which INVERTS the default. A crashing compiler prints no
  `error[` marker, so `VERSE_BIN=/usr/bin/false` and a binary printing
  `panic: boom` both returned `{:ok, :compiled}`. A broken toolchain reading as
  a clean page means every later rung, and the whole loop, validates nothing
  while reporting success.

  The unrecognised case is therefore the most important test in this file, and
  it is the one a rewrite is most likely to lose — the happy paths are obvious
  and the crash path is not.

  ## Why the exemption list is tested by NAME

  `--deny-warnings` turns every warning into a failure, and verse emits W0201
  ("defined but never used") for signals consumed by `@on` handlers and `@view`
  arms — constructs its usage analysis does not trace. Four of those are false
  positives on the page this project ships. A FIFTH, `$fx`, was not: nothing
  consumed the token stream, so streamed tokens arrived in the browser and
  rendered nothing. A blanket "drop every W0201" hid a real defect behind an
  exemption written for a different one.

  So `fx` staying OUT of the list is an assertion, not an omission.
  """

  use ExUnit.Case, async: false

  alias BeamLisp.Spell.Verse

  # `classify/1` and `exempt?/1` are public because they ARE the policy — the
  # half of the module that answers a question about a string rather than about
  # a subprocess. See their docs; the split is the point.
  defp classify(output), do: Verse.classify(output)
  defp exempt?(line), do: Verse.exempt?(line)

  # ── recorded output ────────────────────────────────────────────────────────
  #
  # Shapes taken from real `spacetime check --deny-warnings` runs against the
  # page this project emits. Hand-written approximations were avoided
  # deliberately: a fixture that agrees with the test only proves the test
  # agrees with itself (the same principle `st_edn_test.exs` states).

  @exempt_only """
  warning[W0201]: data source 'draft' is defined but never used
    ┌─ /tmp/spell-demo/page.st:14:1
  warning[W0201]: data source 'status' is defined but never used
  warning[W0201]: data source 'send' is defined but never used
  """

  @real_error """
  error[E0928]: unknown macro "data-subscrib"
    ┌─ /tmp/spell-demo/page.st:22:12
  """

  @unused_stream """
  warning[W0201]: data source 'fx' is defined but never used
  """

  describe "classify — what a non-zero exit said" do
    test "diagnostics that are ALL exempt downgrade to a pass" do
      assert classify(@exempt_only) == :only_exempt_warnings
    end

    test "a real error is a refusal, and the diagnostic is carried out" do
      assert {:problems, [line]} = classify(@real_error)
      assert line =~ "E0928"
    end

    test "an unused STREAM is a refusal — verse is right about those" do
      # Nothing but a bind can consume a stream, so W0201 on one is not the
      # blind spot the exemption exists for. This is the `$fx` case: tokens
      # streamed to a browser that rendered nothing.
      assert {:problems, _} = classify(@unused_stream)
    end

    test "one real problem among exempt warnings is still a refusal" do
      assert {:problems, [line]} = classify(@exempt_only <> @real_error)
      assert line =~ "E0928"
    end
  end

  describe "classify — the inverted default" do
    test "no diagnostics at all is UNRECOGNISED, never a pass" do
      # The recorded defect: a crashing or missing compiler prints no `error[`
      # marker. If this ever answers `:only_exempt_warnings` or anything the
      # caller treats as success, the ladder is validating nothing.
      assert classify("") == :unrecognised
      assert classify("panic: boom\nthread 'main' panicked") == :unrecognised
      assert classify("usage: spacetime <COMMAND>") == :unrecognised
    end

    test "a real binary that cannot run is reported as a problem, not a clean page" do
      # End-to-end through `check/1`, with a binary that exits non-zero and
      # says nothing. This is `VERSE_BIN=/usr/bin/false`, the exact
      # reproduction.
      previous = System.get_env("VERSE_BIN")
      System.put_env("VERSE_BIN", "/usr/bin/false")

      on_exit(fn ->
        if previous, do: System.put_env("VERSE_BIN", previous), else: System.delete_env("VERSE_BIN")
      end)

      page = Path.join(System.tmp_dir!(), "verse-policy-#{System.unique_integer([:positive])}.st")
      File.write!(page, "/* empty */\n")
      on_exit(fn -> File.rm(page) end)

      assert {:error, reason} = Verse.check(page)
      assert reason =~ "without emitting a diagnostic"
    end
  end

  describe "the exemption list" do
    test "covers exactly the sources verse cannot trace" do
      for source <- ~w(draft status send partial error) do
        assert exempt?("warning[W0201]: data source '#{source}' is defined but never used"),
               "#{source} is consumed by an @on or @view arm and must be exempt"
      end
    end

    test "does NOT cover the token stream" do
      refute exempt?("warning[W0201]: data source 'fx' is defined but never used"),
             "exempting the stream is how a real defect hid behind an exemption " <>
               "written for a different one"
    end

    test "does not exempt a different warning code for an exempt name" do
      refute exempt?("warning[W0310]: data source 'draft' shadows a binding")
    end

    test "does not exempt an unknown source" do
      refute exempt?("warning[W0201]: data source 'whatever' is defined but never used")
    end
  end

  describe "class extraction — the two joins' left sides" do
    test "styled classes come out of selectors, compound ones included" do
      css = """
      .bubble[data-role='user'] { color: red; }
      .log .entry { color: blue; }
      main { margin: 0; }
      """

      assert Verse.styled_classes(css) == ["bubble", "entry", "log"]
    end

    test "rendered classes come out of markup in the emitted JS" do
      js = ~s|registerTemplate("x", '<div class="clock face">{@m}</div>')|
      assert Verse.rendered_classes(js) == ["clock", "face"]
    end

    test "bind selectors yield a token only when attribution is certain" do
      # `.a .b`, `.a[x]`, `#id` and `main` may legitimately match host markup
      # the machine never emitted — `&shell` is mounted by the host page. A
      # check that refuses correct definitions is a check that gets switched
      # off, so it fires only on a single bare class.
      assert Verse.class_tokens([".log", ".a .b", ".a[x]", "#id", "main"]) == ["log"]
    end

    test "a MINIFIED stylesheet still yields its selectors" do
      # The scan must not depend on verse's formatting. Anchored to the start of
      # a line — which it was — this answers `[]`, the ghost join becomes
      # `[] -- rendered` (empty), and rung 4 passes every definition while
      # looking exactly as green as a working one.
      assert Verse.styled_classes(".real{color:#fff}.phantom{color:#f00}") ==
               ["phantom", "real"]
    end

    test "selectors nested in an at-rule are seen" do
      assert "narrow" in Verse.styled_classes("@media (max-width: 40rem) { .narrow { gap: 0 } }")
    end

    test "the ghost join is styled MINUS rendered, and nothing else" do
      css = ".real { color: #fff } .phantom { color: #f00 }"
      js = ~s|registerTemplate("t", '<i class="real"></i>')|

      assert Verse.styled_classes(css) -- Verse.rendered_classes(js) == ["phantom"]
    end
  end
end
