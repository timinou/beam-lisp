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
     "638ee5ed4e951a6051d1cd076dbd95f2502a8076d677b63f2c3a68fb3fdfb1c4"},
    # Promoted by wave 14 (next / list* / variadic apply / predicates /
    # reader `#()`). Each was a recorded FAIL before that wave.
    {"slice_04_comp.bl", "jank.accept.comp",
     "0d443f90af3b946aaa37aad4b30ffd8972ed201c2993af482d69284db7af13ff"},
    {"slice_05_juxt.bl", "jank.accept.juxt",
     "b4b6749ff3721789b6f9ba1164200beacd0bbd2d7c7115eca6a1505da1a44bbe"},
    {"slice_06_partial.bl", "jank.accept.partial",
     "91049610d2c834f2ebe48fb4792159b0e20881d2221a627920d964d7c948e7d7"},
    {"slice_08_some.bl", "jank.accept.some",
     "bcd75831ce14743d96360be096f31c9b75b0750587abc4cd782b4b073f9d5cf6"},
    # not-any? is (comp not some) upstream, so its own slice needs the
    # `some` slice loaded alongside it — a real dependency in core.jank,
    # not a beam-lisp gap.
    {"slice_09_not_any.bl", "jank.accept.notany",
     "7138ca6278a5802672310d47aecdc3966ae0e1b640d111fa974ef1a19fbc8066"},
    {"slice_19_trampoline.bl", "jank.accept.trampoline",
     "cfcc184828d5eec2cd564f6086cec74d1c8d21790eeb5bfb915aac4938e4df67"},
    # Promoted by wave 15 (loop*/let*/fn*, &form/&env, form metadata,
    # the clojure.core alias, assert-macro-args) plus the seqable-splice
    # and vector-as-function fixes. These complete the set.
    {"slice_10_thread_macro.bl", "jank.accept.thread",
     "5296714e41323bd79577ad97870205a3df9ff6889ffc38d659a3dfbcdb8f2e94"},
    {"slice_11_thread_last_macro.bl", "jank.accept.threadlast",
     "0addfc66e734fdde1b3d7a937744e728bbc31006fe1b6c84bfd700882845c8eb"},
    {"slice_13_if_let.bl", "jank.accept.iflet",
     "a812ab2bcf40efe521789516656cd8bb90657ce05534b5c2269cac0b482f91ec"},
    {"slice_14_when_let.bl", "jank.accept.whenlet",
     "547eac4f781ff4d30c56a1ebff8b51b5bdb62e208d6f87a3510c46c78e0639fc"},
    {"slice_16_dotimes.bl", "jank.accept.dotimes",
     "4d75d74ce628508e005ec1107a61fc2ad573673f95ea3862b88ba29e3d3040d8"},
    {"slice_17_doseq.bl", "jank.accept.doseq",
     "059f290bc3d7f605fe3f4635ecb0e4c5753b8b484cae05717611778307cf994d"},
    {"slice_18_doto.bl", "jank.accept.doto",
     "e54541f5b3f8c479715d68ef87b00b06ecc20b858400c0f0724e2c9efc3a2856"},
    {"slice_21_memoize.bl", "jank.accept.memoize",
     "cfafa7e7689768fb12808200219a1a60a571b1b3a739706113164aafcd0fd707"}
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

    # --- promoted by wave 14: next / list* / variadic apply /
    # predicates / reader `#()`. Each of these was a recorded FAIL in
    # docs/jank-compat.md before that wave.

    test "comp composes right to left, at every arity" do
      load_slice("slice_04_comp.bl", "jank.accept.comp")
      assert eval_in("jank.accept.comp", "((comp) 7)") == 7
      assert eval_in("jank.accept.comp", "((comp inc) 1)") == 2
      assert eval_in("jank.accept.comp", "((comp inc inc) 1)") == 3
      # the 4-arity path needs list* and variadic apply
      assert eval_in("jank.accept.comp", "((comp inc inc inc inc) 0)") == 4
    end

    test "juxt applies every fn to the same args" do
      load_slice("slice_05_juxt.bl", "jank.accept.juxt")
      # the 4-fn path goes through reduce and a `#()` literal.
      # Upstream juxt conjes onto `[]`, so the result is a vector —
      # beam-lisp keeps vectors and lists structurally distinct.
      assert eval_in("jank.accept.juxt", "((juxt + - * /) 10 2)") ==
               BeamLisp.Vector.new([12, 8, 20, 5.0])
    end

    test "partial fixes leading arguments" do
      load_slice("slice_06_partial.bl", "jank.accept.partial")
      assert eval_in("jank.accept.partial", "((partial + 1) 2)") == 3
      assert eval_in("jank.accept.partial", "((partial + 1 2) 3)") == 6
      assert eval_in("jank.accept.partial", "((partial + 1 2 3) 4)") == 10
    end

    test "some returns the first logical-true result, else nil" do
      load_slice("slice_08_some.bl", "jank.accept.some")
      assert eval_in("jank.accept.some", "(some even? [1 2 3])") == true
      assert eval_in("jank.accept.some", "(some even? [1 3 5])") == nil
    end

    test "not-any? is the complement of some" do
      # Upstream not-any? is (comp not some), so its slice needs the
      # `some` slice in the same namespace. That is core.jank's own
      # dependency, satisfied here with unmodified upstream text.
      load_slice("slice_08_some.bl", "jank.accept.notany")
      load_slice("slice_09_not_any.bl", "jank.accept.notany")
      assert eval_in("jank.accept.notany", "(not-any? even? [1 3 5])") == true
      assert eval_in("jank.accept.notany", "(not-any? even? [1 2])") == false
    end

    test "trampoline runs a thunk-returning loop in constant stack" do
      load_slice("slice_19_trampoline.bl", "jank.accept.trampoline")
      assert eval_in("jank.accept.trampoline", "(trampoline identity 5)") == 5

      # mutual recursion through thunks — the reason trampoline exists,
      # and 100k deep to show it really is constant stack
      assert eval_in("jank.accept.trampoline", """
             (defn ev? [n] (if (= n 0) true (fn [] (od? (- n 1)))))
             (defn od? [n] (if (= n 0) false (fn [] (ev? (- n 1)))))
             (trampoline ev? 100000)
             """) == true
    end
    # --- promoted by wave 15: loop*/let*/fn*, &form/&env, form
    # metadata, the clojure.core alias, assert-macro-args — plus the
    # seqable `~@` splice and vector-as-function fixes those exposed.

    test "-> threads through the first argument position" do
      load_slice("slice_10_thread_macro.bl", "jank.accept.thread")
      assert eval_in("jank.accept.thread", "(-> 5 (+ 3) (* 2))") == 16
      assert eval_in("jank.accept.thread", "(-> 5 inc)") == 6
      # a bare symbol form, not a list — the branch that needs seq?
      assert eval_in("jank.accept.thread", "(-> 5)") == 5
    end

    test "->> threads through the last argument position" do
      load_slice("slice_11_thread_last_macro.bl", "jank.accept.threadlast")
      assert eval_in("jank.accept.threadlast", "(->> 5 (- 8))") == 3
      assert eval_in("jank.accept.threadlast", "(->> [1 2 3] (map inc) (reduce + 0))") == 9
    end

    test "if-let binds only when the test is truthy" do
      load_slice("slice_13_if_let.bl", "jank.accept.iflet")
      assert eval_in("jank.accept.iflet", "(if-let [x 5] x :none)") == 5
      assert eval_in("jank.accept.iflet", "(if-let [x nil] x :none)") == :none
      assert eval_in("jank.accept.iflet", "(if-let [x false] x :none)") == :none
    end

    test "when-let binds and runs its body only when truthy" do
      load_slice("slice_13_if_let.bl", "jank.accept.whenlet")
      load_slice("slice_14_when_let.bl", "jank.accept.whenlet")
      assert eval_in("jank.accept.whenlet", "(when-let [x 5] (* x 2))") == 10
      assert eval_in("jank.accept.whenlet", "(when-let [x nil] (* x 2))") == nil
    end

    test "dotimes runs its body n times, binding the index" do
      load_slice("slice_16_dotimes.bl", "jank.accept.dotimes")

      assert eval_in("jank.accept.dotimes", """
             (def acc (atom 0))
             (dotimes [i 5] (swap! acc (fn [a] (+ a i))))
             @acc
             """) == 10
    end

    test "doseq walks a collection for side effects" do
      load_slice("slice_13_if_let.bl", "jank.accept.doseq")
      load_slice("slice_14_when_let.bl", "jank.accept.doseq")
      load_slice("slice_17_doseq.bl", "jank.accept.doseq")

      assert eval_in("jank.accept.doseq", """
             (def total (atom 0))
             (doseq [x [1 2 3 4]] (swap! total (fn [a] (+ a x))))
             @total
             """) == 10
    end

    test "doto threads a value through side-effecting forms and returns it" do
      load_slice("slice_18_doto.bl", "jank.accept.doto")

      # doto is the reason form metadata had to exist: it rebuilds each
      # form with (with-meta … (meta f)).
      assert eval_in("jank.accept.doto", """
             (def seen (atom []))
             (doto 7
               (#(swap! seen conj %))
               (#(swap! seen conj (* 2 %))))
             """) == 7
    end

    test "memoize caches by argument list" do
      load_slice("slice_13_if_let.bl", "jank.accept.memoize")
      load_slice("slice_12_map_entries.bl", "jank.accept.memoize")
      load_slice("slice_21_memoize.bl", "jank.accept.memoize")

      # calls counts real invocations, so a cache hit must not bump it
      assert eval_in("jank.accept.memoize", """
             (def calls (atom 0))
             (def slow (fn [n] (do (swap! calls inc) (* n n))))
             (def fast (memoize slow))
             (fast 4) (fast 4) (fast 4)
             [(fast 4) @calls]
             """) == BeamLisp.Vector.new([16, 1])
    end
  end
end
