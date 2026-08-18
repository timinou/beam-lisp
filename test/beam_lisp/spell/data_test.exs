defmodule BeamLisp.Spell.DataTest do
  @moduledoc """
  The one boundary, and the properties that make it a boundary.

  Three claims are load-bearing and each has its own section:

    1. it cannot grow the atom table, whatever a model sends
    2. it cannot evaluate anything, whatever a model sends
    3. it does not lose data on the way through

  The first two used to be one claim ("the printer escapes correctly") and were
  false: a crafted map key closed the printed call and opened a new form, so
  `(def pwned 99)` evaluated before any validation ran. That payload is
  replayed here and must stay inert.
  """

  use ExUnit.Case, async: false
  use BeamLisp.SpellCase

  alias BeamLisp.Spell.Data
  alias BeamLisp.Vector

  @recorded_injection "kind \"view\"))\n(def pwned 99)\n(def z {:kind"

  describe "the atom table cannot be grown" do
    test "a thousand distinct unknown keys intern nothing" do
      # The property that makes this safe by CONSTRUCTION rather than by
      # vigilance. Atoms are never collected and a full table aborts the VM
      # uncatchably, so "we validate before interning" is not enough — the
      # conversion must be incapable of interning.
      payload = Map.new(1..1000, fn i -> {"unknown_key_#{i}_#{System.unique_integer()}", i} end)

      before = :erlang.system_info(:atom_count)
      Data.to_bl(payload, :all_strings)
      grew = :erlang.system_info(:atom_count) - before

      # A BUDGET, not equality. The count is VM-global: ExUnit, logging and
      # any other process intern atoms of their own while this runs, so `==`
      # failed whenever this test ran first in a fresh VM (before the rest of
      # the file had warmed the machinery) and passed when it ran later — a
      # test whose result depended on its neighbours.
      #
      # 1000 crafted keys must not move the table meaningfully. The real
      # assertion is the ratio: if the conversion interned its input, `grew`
      # would be ~1000, not a handful of unrelated atoms from elsewhere in the
      # VM.
      assert grew < 100,
             "converting 1000 crafted keys grew the atom table by #{grew} — " <>
               "a model-supplied key is being interned, and the atom table is " <>
               "writable from the wire"
    end

    test "the conversion interns nothing at all when the VM is otherwise idle" do
      # The exact claim, measured where nothing else is running: two identical
      # conversions back to back. The first may pay for lazily-resolved
      # machinery; the second cannot, so its delta is the conversion's own
      # appetite for atoms and must be exactly zero.
      payload = Map.new(1..1000, fn i -> {"other_key_#{i}_#{System.unique_integer()}", i} end)
      Data.to_bl(payload, :all_strings)

      before = :erlang.system_info(:atom_count)
      Data.to_bl(payload, :all_strings)

      assert :erlang.system_info(:atom_count) == before,
             "a model-supplied key was interned — the atom table is writable from the wire"
    end

    test "an unknown key stays a string, and its value survives" do
      converted = Data.to_bl(%{"nonesuch" => 1}, :all_strings)

      assert converted == %{"nonesuch" => 1}
    end

    test "the recorded injection payload converts to an inert string key" do
      converted = Data.to_bl(%{@recorded_injection => "view"}, :all_strings)

      assert Map.keys(converted) == [@recorded_injection]
      assert is_binary(hd(Map.keys(converted)))
    end
  end

  describe "nothing is evaluated" do
    test "the recorded injection does not define anything" do
      # The end-to-end claim. `pwned` must not exist afterwards — not because
      # the payload was detected, but because there is no evaluator on this
      # path to detect it for.
      Data.to_bl(%{@recorded_injection => "view"}, :all_strings)

      assert BeamLisp.Env.fetch("user", "pwned") == :error
    end

    test "a value that looks like source is just a string" do
      converted = Data.to_bl(%{"html" => "(def pwned 99)"}, :all_strings)

      assert converted == %{"html" => "(def pwned 99)"}
      assert BeamLisp.Env.fetch("user", "pwned") == :error
    end
  end

  describe "shapes survive the crossing" do
    test "lists become vectors, because beam-lisp's mapv wants one" do
      # An Elixir list reads as a beam-lisp LIST, a different type: `get` by
      # index and destructuring behave differently, so an emitter walking a
      # list where it expects a vector produces subtly wrong terms rather than
      # an error.
      assert %Vector{} = Data.to_bl([1, 2, 3], :all_strings)
      assert Data.to_bl([1, 2], :all_strings) |> Vector.to_list() == [1, 2]
    end

    test "conversion is deep" do
      converted =
        Data.to_bl(
          %{"templates" => [%{"name" => "t", "html" => "<i/>"}]},
          :all_strings
        )

      assert %Vector{} = converted["templates"]
      assert [%{"name" => "t", "html" => "<i/>"}] = converted["templates"] |> Vector.to_list()
    end

    test "free-form maps keep their string keys" do
      # CSS declarations and push field names are open sets read POSITIONALLY
      # by the emitters, so a string key is what they want. This is why the
      # boundary drops rather than refuses: `font-size` is not a vocabulary
      # word and must not become one.
      converted = Data.to_bl(%{"rules" => %{"font-size" => "1rem"}}, :all_strings)

      assert converted == %{"rules" => %{"font-size" => "1rem"}}
    end

    test "a struct is refused loudly" do
      assert_raise ArgumentError, fn ->
        Data.to_bl(%{"when" => ~D[2026-08-16]}, :all_strings)
      end
    end
  end

  describe "coming back" do
    test "vectors become lists and keywords become strings" do
      assert Data.from_bl(Vector.new([:a, :b])) == ["a", "b"]
    end

    test "booleans and nil stay JSON values" do
      # `"false"` is a non-empty string, which is TRUTHY in the browser. A
      # boolean assign stringified here renders as its own opposite.
      assert Data.from_bl(%{ok: true, off: false, nothing: nil}) ==
               %{"ok" => true, "off" => false, "nothing" => nil}
    end

    test "a machine report survives JSON encoding" do
      # The real consumer: `report.json` is read by the browser, by peek.sh and
      # by a human. A value that cannot encode makes the whole file unwritable.
      report = Data.from_bl(fetch!("spell.live", "machine-report").(seeded_machine()))

      assert is_binary(JSON.encode!(report))
    end

    test "round-tripping data through both directions preserves it" do
      original = %{
        "kind" => "view",
        "name" => "clock",
        "rules" => %{"font-size" => "1rem"},
        "templates" => [%{"name" => "t", "html" => "<i/>"}]
      }

      assert original |> Data.to_bl(:all_strings) |> Data.from_bl() == original
    end
  end
end