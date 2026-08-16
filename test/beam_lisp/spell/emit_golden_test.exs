defmodule BeamLisp.Spell.EmitGoldenTest do
  @moduledoc """
  What the seeded machine emits, pinned byte for byte.

  ## Why a golden and not a property

  These functions produce a document a COMPILER reads. There is no useful
  property short of "verse accepts it", and verse is a subprocess this suite
  deliberately does not run (see `verse_policy_test.exs` for that boundary). So
  what is asserted here is the thing a refactor must not change: the exact
  bytes, plus a handful of structural claims that say WHY those bytes are
  right — a golden with no claims beside it fails as "something changed" and
  teaches the reader nothing.

  ## Why this exists before PLAN-027 moves anything

  `spell.live`'s emitters had no Elixir-side test at all. W4 of that plan turns
  document merging from text-scanning into data-merging, and W6 moves the whole
  namespace to `spell.page`. Neither is safe without a witness that the output
  did not move — a refactor of untested code is a rewrite with extra steps.

  The fixtures were captured from the code as it stood at the start of that
  work (`test/fixtures/golden/`), so a diff here means the emitter changed, not
  that the test drifted.
  """

  use ExUnit.Case, async: false
  use BeamLisp.SpellCase

  @golden "test/fixtures/golden"

  defp emit(fun), do: fetch!("spell.live", fun).(seeded_machine())

  describe "the seam document" do
    test "matches the recorded bytes" do
      assert emit("machine-seam-edn") == File.read!("#{@golden}/seed-seam.edn")
    end

    test "declares exactly one :st/imports key" do
      # The merge exists because two concatenated documents produce two
      # `:st/imports` keys and the reader silently takes one of them. That is
      # the defect `merge-docs` was written against, so it is the one thing a
      # rewrite of the merge must keep true.
      assert emit("machine-seam-edn") |> occurrences(":st/imports") == 1
    end

    test "subscribes every contract assign to its host" do
      # A `data-subscribe` per assign is what makes the page's signals arrive
      # from the server rather than from the browser. The seed contract
      # declares four; a fifth appearing here means an assign was added, and a
      # fourth missing means a page reads an unbound signal.
      doc = emit("machine-seam-edn")

      for assign <- ~w(error messages partial status) do
        assert doc =~ "(data-subscribe :name $#{assign} :host $chat-live :assign #{assign})",
               "no subscription for @#{assign} — the page would read an unbound signal"
      end
    end
  end

  describe "the view document" do
    test "matches the recorded bytes" do
      assert emit("machine-view-edn") == File.read!("#{@golden}/seed-view.edn")
    end

    test "carries the style plane as :st/scopes" do
      # `spacetime st` does not print `:st/scopes`, which is why `machine-css`
      # exists as a separate emitter. The DOCUMENT still has to carry them, or
      # the page verse checks and the page a browser loads describe different
      # styling.
      assert emit("machine-view-edn") =~ ":st/scopes ["
    end

    test "an escaped quote in template HTML does not truncate the document" do
      # The specific defect `doc-section` was hardened against: a scanner that
      # toggles string-mode on every quote leaves it at the backslash, then
      # reads the next `]` as the section terminator and truncates mid-template.
      #
      # Asserting on the SEEDED machine rather than a synthetic one, because the
      # seed's own templates carry attribute quotes — this is a regression test
      # that a rewrite of the merge (PLAN-027 W4) must still satisfy.
      doc = emit("machine-view-edn")

      assert String.ends_with?(String.trim(doc), "}"),
             "the document ends mid-form — the merge truncated it"

      assert balanced?(doc), "brackets do not balance outside string literals"
    end
  end

  describe "the style plane" do
    test "matches the recorded bytes" do
      assert emit("machine-css") == File.read!("#{@golden}/seed-style.css")
    end

    test "is stable across repeated emits" do
      # CSS cascades, so order is meaning. A map iterating differently between
      # two emits would produce a page that looks different for no reason the
      # diff can explain.
      assert emit("machine-css") == emit("machine-css")
    end
  end

  describe "what the page preamble is derived from" do
    test "locals are the page-local signals, and nothing else" do
      # `draft` is written by the browser and crosses no seam. `m` and `t` are
      # `@each` loop variables: declaring one as a page signal would create a
      # second, permanently empty name a template could resolve to instead.
      assert plain(emit("machine-locals")) == ["draft"]
    end

    test "hosts are the registered contracts" do
      assert plain(emit("machine-hosts")) == ["chat-live"]
    end

    test "bind selectors are ours, never verse's runtime" do
      # Rung 4 takes its left side from this list. Scanning the emitted bundle
      # instead reported `.ad-form` and friends — library code we did not write
      # and cannot judge.
      assert plain(emit("machine-bind-selectors")) ==
               [".composer__input", ".composer__send", ".log"]
    end
  end

  describe "the machine report" do
    test "reports no errors for the seed" do
      report = plain(fetch!("spell.live", "machine-report").(seeded_machine()))

      assert report["errors"] == [],
             "the seeded machine must be clean — everything else is measured against it"
    end

    test "the report's locals are the EXEMPTION set, a superset of the declarable ones" do
      # Two different questions wearing one word, and the difference is
      # load-bearing:
      #
      #   machine-locals   (view-signals)  names the page must DECLARE
      #   report :locals   (view-locals)   names the orphan check must EXEMPT
      #
      # The second additionally carries `@each` loop variables (`m` in the seed
      # view). Declaring one as a page signal creates a second, permanently
      # empty name a template's `{@m.field}` could resolve to instead — a page
      # that compiles, renders, and shows blank rows. Exempting one is simply
      # correct: a loop variable is published by nobody.
      #
      # So they must NOT be equal, and the exemption set must contain the
      # declarable set. Asserting the containment rather than either list keeps
      # this true when a view is added.
      report = plain(fetch!("spell.live", "machine-report").(seeded_machine()))
      declarable = plain(emit("machine-locals"))

      assert declarable -- report["locals"] == [],
             "a name the page declares is not exempt from the orphan check — " <>
               "the report would contradict the ladder that just passed"

      assert report["locals"] == ["draft", "m"]
      assert declarable == ["draft"]
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp occurrences(text, needle),
    do: text |> String.split(needle) |> length() |> Kernel.-(1)

  # Bracket balance OUTSIDE string literals — the same state machine the merge
  # itself has to implement, written independently here so a bug in one does
  # not hide a bug in the other.
  defp balanced?(doc) do
    doc
    |> String.to_charlist()
    |> Enum.reduce_while({0, false, false}, fn
      _c, {depth, _in_str, true} when depth < 0 -> {:halt, {depth, false, true}}
      ?\\, {depth, true, _} -> {:cont, {depth, true, true}}
      _c, {depth, true, true} -> {:cont, {depth, true, false}}
      ?", {depth, in_str, false} -> {:cont, {depth, not in_str, false}}
      ?[, {depth, false, false} -> {:cont, {depth + 1, false, false}}
      ?], {depth, false, false} -> {:cont, {depth - 1, false, false}}
      _c, acc -> {:cont, acc}
    end)
    |> case do
      {0, false, _} -> true
      _ -> false
    end
  end
end
