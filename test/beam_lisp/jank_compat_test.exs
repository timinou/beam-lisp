defmodule BeamLisp.JankCompatTest do
  # The thesis: beam-lisp is "jank's language, BEAM's runtime". jank
  # ships its stdlib as `core.jank` — Clojure source written for jank.
  # Loading slices of it *unmodified* turns fidelity from an opinion
  # into a test. Every fixture under test/fixtures/jank/ is a verbatim
  # block of jank's core.jank, copied with its sha256 in a header; the
  # harness below wraps each in a throwaway `(ns …)` and evaluates it.
  #
  # ONLY slices that load AND behave correctly are tested here. A slice
  # that needs a local edit is a FAIL, recorded in docs/jank-compat.md,
  # never patched into passing. docs/jank-compat.md holds the full
  # attempted-slice measurement (21 slices, per-slice verdict + reason).
  use ExUnit.Case, async: false

  @moduletag :jank_compat

  # Provenance of the vendored source — compiler+runtime/src/jank/clojure/core.jank
  # in https://github.com/jank-lang/jank at commit 30285949933065417c6311a91902b7866ab60f87
  # (2026-08-01). License EPL-1.0.
  @commit "30285949933065417c6311a91902b7866ab60f87"

  # Accepted slices: {fixture, ns, sha256-of-code-portion}. The sha256 is
  # of the fixture with its `;` header comments removed — i.e. exactly the
  # upstream text. If any fixture drifts from upstream, the checksum test
  # below fails and the fidelity claim is void.
  @accepted [
    {"slice_01_constantly.bl", "jank.accept.constantly",
     "03654db26364c079af25d71d547633a53e5e1653d76123940954582fe1e0e7f1"},
    {"slice_02_identity.bl", "jank.accept.identity",
     "e3a01a8ccc464af57f5c3365ae6b112e00bd9590de08aba8460ae5ae9bf398ea"},
    {"slice_03_complement.bl", "jank.accept.complement",
     "23b3261736818c3560d3438c4e48d92226d93a0320146e6a115e180c3d87cb40"},
    {"slice_07_fnil.bl", "jank.accept.fnil",
     "340a6d700f07b3d06ef730648d1ff506453ef922595b75290b03340020ec769a"},
    {"slice_12_map_entries.bl", "jank.accept.entries",
     "b4a9e1bd2bdda80d5f2fa41091e60e47da3b50312d63d7b300653f0922549c79"},
    {"slice_15_if_not.bl", "jank.accept.ifnot",
     "1b1b4b07fc9887d3b0673a913a31a70a4822441dd1792176a47a7cf4c66378f1"},
    {"slice_20_while.bl", "jank.accept.while",
     "638ee5ed4e951a6051d1cd076dbd95f2502a8076d677b63f2c3a68fb3fdfb1c4"}
  ]

  setup_all do
    BeamLisp.init()
    :ok
  end

  # The fixture minus its provenance header. The header lines all begin
  # with `;`; the slice text itself is pure defn/macro forms.
  defp fixture_code(fixture) do
    Path.join(["test", "fixtures", "jank", fixture])
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, ";"))
    |> Enum.join("\n")
  end

  defp load_slice(fixture, ns) do
    source = "(ns #{ns})\n" <> fixture_code(fixture)
    BeamLisp.Compiler.eval_string(source, BeamLisp.Compiler.new_env(ns))
  end

  defp eval_in(ns, source) do
    BeamLisp.Compiler.eval_string(source, BeamLisp.Compiler.new_env(ns))
  end

  test "vendored slices are byte-for-byte upstream (checksum, no local edits)" do
    for {fixture, _ns, expected} <- @accepted do
      actual = :crypto.hash(:sha256, fixture_code(fixture)) |> Base.encode16(case: :lower)

      assert actual == expected,
             "#{fixture} drifts from upstream core.jank@#{@commit} — the fidelity claim is void"
    end
  end

  describe "verbatim jank core.jank slices" do
    test "constantly returns its arg regardless of args" do
      load_slice("slice_01_constantly.bl", "jank.accept.constantly")
      assert eval_in("jank.accept.constantly", "((constantly 5) 1 2 3)") == 5
      assert eval_in("jank.accept.constantly", "((constantly :k))") == :k
    end

    test "identity returns its argument" do
      load_slice("slice_02_identity.bl", "jank.accept.identity")
      assert eval_in("jank.accept.identity", "(identity :x)") == :x
    end

    test "complement flips a predicate" do
      load_slice("slice_03_complement.bl", "jank.accept.complement")
      assert eval_in("jank.accept.complement", "((complement even?) 3)") == true
      assert eval_in("jank.accept.complement", "((complement even?) 4)") == false
      assert eval_in("jank.accept.complement", "((complement =) 1 2)") == true
    end

    test "fnil patches nil arguments" do
      load_slice("slice_07_fnil.bl", "jank.accept.fnil")
      assert eval_in("jank.accept.fnil", "((fnil + 0) nil 5)") == 5
      assert eval_in("jank.accept.fnil", "((fnil + 0 10) 5 nil)") == 15
      assert eval_in("jank.accept.fnil", "((fnil + 0) 3 4)") == 7
    end

    test "key and val read a map entry" do
      load_slice("slice_12_map_entries.bl", "jank.accept.entries")
      assert eval_in("jank.accept.entries", "(key [:alice 3])") == :alice
      assert eval_in("jank.accept.entries", "(val [:alice 3])") == 3
    end

    test "if-not selects the else branch when test is truthy" do
      load_slice("slice_15_if_not.bl", "jank.accept.ifnot")
      assert eval_in("jank.accept.ifnot", "(if-not true 1 2)") == 2
      assert eval_in("jank.accept.ifnot", "(if-not false 1 2)") == 1
    end

    test "while loops until its test is falsy" do
      load_slice("slice_20_while.bl", "jank.accept.while")
      assert eval_in("jank.accept.while", "(def c (atom 0)) (while (< @c 3) (swap! c inc)) @c") == 3
    end
  end
end
