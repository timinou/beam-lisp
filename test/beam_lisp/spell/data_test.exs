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

  @recorded_injection "kind \"view\"}))\n(def pwned 99)\n(def z {:kind"

  describe "the atom table cannot be grown" do
    test "a thousand distinct unknown keys intern nothing" do
      # The property that makes this safe by CONSTRUCTION rather than by
      # vigilance. Atoms are never collected and a full table aborts the VM
      # uncatchably, so "we validate before interning" is not enough — the
      # conversion must be incapable of interning.
      payload = Map.new(1..1000, fn i -> {"unknown_key_#{i}_#{System.unique_integer()}", i} end)
      keys = Data.proposal_keys()

      before = :erlang.system_info(:atom_count)
      Data.to_bl(payload, keys)
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
      # VM. `proposal_keys()` is resolved BEFORE the window so the vocabulary's
      # own (legitimate, one-time) interning is not counted here — it is the
      # subject of the next test.
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
      keys = Data.proposal_keys()
      Data.to_bl(payload, keys)

      before = :erlang.system_info(:atom_count)
      Data.to_bl(payload, keys)

      assert :erlang.system_info(:atom_count) == before,
             "a model-supplied key was interned — the atom table is writable from the wire"
    end

    test "an unknown key stays a string, and its value survives" do
      converted = Data.to_bl(%{"nonesuch" => 1, "kind" => "view"}, ["kind"])

      assert converted == %{"nonesuch" => 1, kind: "view"}
    end

    test "the recorded injection payload converts to an inert string key" do
      converted = Data.to_bl(%{@recorded_injection => "view"}, Data.proposal_keys())

      assert Map.keys(converted) == [@recorded_injection]
      assert is_binary(hd(Map.keys(converted)))
    end
  end

  describe "nothing is evaluated" do
    test "the recorded injection does not define anything" do
      # The end-to-end claim. `pwned` must not exist afterwards — not because
      # the payload was detected, but because there is no evaluator on this
      # path to detect it for.
      Data.to_bl(%{@recorded_injection => "view", "name" => "x"}, Data.proposal_keys())

      assert BeamLisp.Env.fetch("user", "pwned") == :error
    end

    test "a value that looks like source is just a string" do
      converted = Data.to_bl(%{"html" => "(def pwned 99)"}, ["html"])

      assert converted == %{html: "(def pwned 99)"}
      assert BeamLisp.Env.fetch("user", "pwned") == :error
    end
  end

  describe "shapes survive the crossing" do
    test "a declared key becomes the keyword the reader indexes by" do
      assert Data.to_bl(%{"kind" => "view"}, ["kind"]) == %{kind: "view"}
    end

    test "lists become vectors, because beam-lisp's mapv wants one" do
      # An Elixir list reads as a beam-lisp LIST, a different type: `get` by
      # index and destructuring behave differently, so an emitter walking a
      # list where it expects a vector produces subtly wrong terms rather than
      # an error.
      assert %Vector{} = Data.to_bl([1, 2, 3], [])
      assert Data.to_bl([1, 2], []) |> Vector.to_list() == [1, 2]
    end

    test "conversion is deep" do
      converted =
        Data.to_bl(
          %{"templates" => [%{"name" => "t", "html" => "<i/>"}]},
          ["templates", "name", "html"]
        )

      assert %{templates: %Vector{}} = converted
      assert [%{name: "t", html: "<i/>"}] = converted.templates |> Vector.to_list()
    end

    test "free-form maps keep their string keys" do
      # CSS declarations and push field names are open sets read POSITIONALLY
      # by the emitters, so a string key is what they want. This is why the
      # boundary drops rather than refuses: `font-size` is not a vocabulary
      # word and must not become one.
      converted = Data.to_bl(%{"rules" => %{"font-size" => "1rem"}}, ["rules"])

      assert converted == %{rules: %{"font-size" => "1rem"}}
    end

    test "a struct is refused loudly" do
      assert_raise ArgumentError, ~r/Date/, fn ->
        Data.to_bl(%{"when" => ~D[2026-08-16]}, ["when"])
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

    test "round-tripping a proposal through both directions preserves it" do
      original = %{
        "kind" => "view",
        "name" => "clock",
        "rules" => %{"font-size" => "1rem"},
        "templates" => [%{"name" => "t", "html" => "<i/>"}]
      }

      assert original |> Data.to_bl(Data.proposal_keys()) |> Data.from_bl() == original
    end
  end

  describe "the vocabulary interns what it lists" do
    test "every declared key converts to a KEYWORD, not a string" do
      # The property, asserted directly, because its absence was silent and
      # expensive.
      #
      # `String.to_existing_atom/1` is what makes the boundary unable to grow
      # the atom table — but it also means a listed name whose atom does not
      # exist cannot convert. `:rationale` was exactly that: listed, but never
      # written as a literal anywhere in `spell.define` (it is built by
      # `(keyword f)` at runtime), so it stayed a STRING key.
      #
      # The consequence was a correct-looking rejection of a correct proposal:
      # rung 1 reported "a proposal needs rationale" for a proposal that had
      # one, because it looked the key up as `:rationale` and found only
      # `"rationale"`. Nothing raised. The fix is that the vocabulary spells
      # its names as keywords, so loading the namespace interns them all.
      keys = Data.proposal_keys()
      payload = Map.new(keys, fn k -> {k, "v"} end)

      unconverted =
        payload
        |> Data.to_bl(keys)
        |> Map.keys()
        |> Enum.filter(&is_binary/1)

      assert unconverted == [],
             "these vocabulary names did not convert to keywords: #{inspect(unconverted)} — " <>
               "the reader will look them up as keywords and see fields that are not there"
    end

    test "a listed name that nothing interned fails LOUDLY" do
      # The guard on the guarantee. A rescue used to swallow this and fall back
      # to a string, which is what let the `:rationale` defect live: a silent
      # degradation at a boundary produces a wrong answer with no error.
      assert_raise ArgumentError, ~r/vocabulary lists/, fn ->
        Data.to_bl(%{"never_interned_anywhere_xyzzy" => 1}, ["never_interned_anywhere_xyzzy"])
      end
    end
  end

  describe "the vocabulary" do
    test "comes from spell.define, not from a copy" do
      keys = Data.proposal_keys()

      # Every field the tool schema declares must be readable. When these
      # disagree, a model fills in a field the reader silently drops — the
      # definition is accepted and the feature is missing.
      for field <- ~w(kind name rationale assigns events pushes templates style binds) do
        assert field in keys, "the reader does not know the schema's #{field} field"
      end

      # And the shapes only the emitter reads — absent from the JSON schema's
      # top level, but read by `bind-form`.
      for field <- ~w(each on view binding as template arms fire arg value) do
        assert field in keys, "bind-form reads #{field} but the vocabulary omits it"
      end
    end
  end
end
