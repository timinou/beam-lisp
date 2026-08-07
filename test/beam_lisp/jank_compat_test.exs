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
     "cfafa7e7689768fb12808200219a1a60a571b1b3a739706113164aafcd0fd707"},
    # Promoted by wave 16 (widen-the-sample). 43 new slices attempted,
    # 15 behaved; the rest are recorded FAILs in docs/jank-compat.md.
    # These complete the sample at 36 of 64.
    {"slice_22_reverse.bl", "jank.accept.reverse",
     "79265cf89aab4f747f54b27c984c687c75a1505048f0495c6938573431bd1fbf"},
    {"slice_23_run.bl", "jank.accept.run",
     "c589b14414937b5681ca8a05572718e4242759fcce02471f6a4522b07e47594c"},
    {"slice_24_every_pred.bl", "jank.accept.everypred",
     "4cc8cfea26d8ea7682b54626edb030239202e154f47574872fcf26b7b9d7f80b"},
    {"slice_25_some_fn.bl", "jank.accept.somefn",
     "47d0b4ce578690d35702c16c5c792acb4bf82bd69e929f57b9e70499217c07c7"},
    {"slice_34_if_some.bl", "jank.accept.ifsome",
     "ccb169de75f32180ff3f43a03f1ba7473bacee7dd4ddef5483fba877c5fbd460"},
    {"slice_35_when_some.bl", "jank.accept.whensome",
     "58ea65a03ef3404e226fde65e7230b9618523827f6f65356e056a8882d911d2d"},
    {"slice_36_repeatedly.bl", "jank.accept.repeatedly",
     "3511d9a9dc9c549f326a88d1dce4d71ed075c5e7cd0f5ba5b8aea1633b1463d5"},
    {"slice_37_take_while.bl", "jank.accept.takewhile",
     "6a4478916931897c608aa5d0c56c001422073264124cd015fd3cb2f8070a2af2"},
    {"slice_38_drop_while.bl", "jank.accept.dropwhile",
     "ad377566a163caf22ee6d2f66804e324e2c9d8522fb02fd8a10f27c6308cf104"},
    {"slice_39_split_at.bl", "jank.accept.splitat",
     "3b551dda30e6cfe4120735231458451f4e37e6f52bdd3e158443df410a2782ca"},
    {"slice_40_interleave.bl", "jank.accept.interleave",
     "a4063bb35431e45f546c18046227b5897401effffd8281c6601e7645b1a9e29b"},
    {"slice_47_update.bl", "jank.accept.update",
     "a19c83c76573376c6d586e787155cdd73d676e059b636456cdb4d0d74d6c9b7a"},
    {"slice_48_mapcat.bl", "jank.accept.mapcat",
     "866f203cd2a1bfac9a2301a66e7e7beef082f0297d69e0b0e129edcef5da594d"},
    {"slice_51_remove.bl", "jank.accept.remove",
     "b1be84ec0aefdb32d950242882e57ffe7baf1ce90db799b8f6b86fb2ab53ef37"},
    {"slice_62_max_key.bl", "jank.accept.maxkey",
     "d9e57aef2ca626d8c5fb3cd3d6ef584f659d4fa2abbcfd27a286dbdba09f5ff8"},
    # Unlocked by nil-terminating an exhausted `&` rest: these two did
    # not fail before, they HUNG — upstream recurs while `more` is
    # truthy, and an empty collection is truthy.
    {"slice_45_assoc_in.bl", "jank.accept.associn",
     "2df0f403010a8e5a72d1df13ded445ec96dab8b8fc1429dc123782e6e14e8443"},
    {"slice_46_update_in.bl", "jank.accept.updatein",
     "ed722b49f086d184d7d04eed9570857acace2ad6b508778da72954978cc2a04d"},
    # Wave 17: transients (keys/vals/zipmap/frequencies/group-by) and
    # the prelude seq layer butlast/nthrest/partition/*assert* the
    # conditional-threading macros are built on.
    {"slice_41_partition.bl", "jank.accept.partition",
     "9ba50270a5fb48344fb6049628cec89fcb1090983c023f1cf63cbabf178eeff2"},
    {"slice_53_cond_arrow.bl", "jank.accept.condarrow",
     "3980728e6f17474d9d21621d8661576f92a6bb3fb5d9405cc44497026df8281c"},
    {"slice_54_cond_arrow_last.bl", "jank.accept.condarrowlast",
     "b3338f0ae1ea4ee0205dcaa685f753f39b23a8e69bb96379abb0d7cd4b682585"},
    {"slice_55_as_arrow.bl", "jank.accept.asarrow",
     "bbce6008271cea925045ca741fa6e294e7e1b01a36af8f859d37ce606b5f5192"},
    {"slice_56_some_arrow.bl", "jank.accept.somearrow",
     "ead9fc9d9db56490d2d3579b412f834f2952f8eb3660cfb3e4b4b92ce883c2f5"},
    {"slice_57_some_arrow_last.bl", "jank.accept.somearrowlast",
     "b5a364ef2efa378293dde55cb3c73939d15955eb5800d675216ef1c10e0d72a6"},
    {"slice_64_assert.bl", "jank.accept.assert",
     "aeb91a6e42ecdbe15823826e472fd6e3a443dd39ada97072149db48cbf4235a9"},
    {"slice_26_keys.bl", "jank.accept.keys",
     "9c947410891c60e7b1394df86a42b4adfd304ca2885f3839054f1070fa9aca94"},
    {"slice_27_vals.bl", "jank.accept.vals",
     "39e254cf5196e78d0eb0814e9e2cf3946205b7176bf92db78c8ee8f3727d5104"},
    {"slice_29_zipmap.bl", "jank.accept.zipmap",
     "643ca59090d95edd577566c98798a4df37ca050151ffd5a5377bca1c05dedd00"},
    {"slice_42_frequencies.bl", "jank.accept.frequencies",
     "f545d75b4156fe059033984775c2d57d41bce1cf217db36c8c075d678741a1ca"},
    {"slice_43_group_by.bl", "jank.accept.groupby",
     "f6e170b41433d38b09ab7e3ecc6c6541cd13c708a24a0fb83a8892656d38e852"},
    # Unlocked by fixing the `<=` link: Erlang spells it `=<`, so the
    # 2-arity call linked to a BIF that does not exist.
    {"slice_63_min_key.bl", "jank.accept.minkey",
     "32026ae941ec5598e27b64584ff7e3c7f7d9818d5a06c274ec1a5c844dfbf40e"}
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

    # --- promoted by wave 16: the widened sample. 43 new slices were
    # attempted (docs/jank-compat.md), of which these 15 behaved. Each
    # is called with its own upstream docstring example. Slices that
    # need a co-loaded dependency name it (some-fn needs `some`, remove
    # needs `complement`) — core.jank's own deps, satisfied verbatim.

    test "reverse returns the items in reverse order" do
      load_slice("slice_22_reverse.bl", "jank.accept.reverse")
      assert eval_in("jank.accept.reverse", "(reverse [1 2 3])") == [3, 2, 1]
      assert eval_in("jank.accept.reverse", "(reverse '(1 2 3))") == [3, 2, 1]
    end

    test "run! reduces a proc for side effects and returns nil" do
      load_slice("slice_23_run.bl", "jank.accept.run")
      assert eval_in("jank.accept.run", """
             (def a (atom 0))
             (def r (run! (fn [x] (swap! a + x)) [1 2 3]))
             [r @a]
             """) == BeamLisp.Vector.new([nil, 6])
    end

    test "every-pred combines predicates with and" do
      load_slice("slice_24_every_pred.bl", "jank.accept.everypred")
      assert eval_in("jank.accept.everypred", "((every-pred even? pos?) 4)") == true
      assert eval_in("jank.accept.everypred", "((every-pred even? pos?) 3)") == false
      assert eval_in("jank.accept.everypred", "((every-pred even?) 2 4 6)") == true
    end

    test "some-fn combines predicates with or, returning the first truthy" do
      # Upstream some-fn's &-arity calls `some`, so this slice needs the
      # `some` slice in the same namespace (core.jank's own dependency).
      load_slice("slice_08_some.bl", "jank.accept.somefn")
      load_slice("slice_25_some_fn.bl", "jank.accept.somefn")
      assert eval_in("jank.accept.somefn", "((some-fn even? pos?) 3)") == true
      assert eval_in("jank.accept.somefn", "((some-fn odd?) 2 4 6)") == false
      assert eval_in("jank.accept.somefn", "((some-fn even? pos?) 1 3 4)") == true
    end

    test "if-some binds only when the test is non-nil" do
      load_slice("slice_34_if_some.bl", "jank.accept.ifsome")
      assert eval_in("jank.accept.ifsome", "(if-some [x 5] x :none)") == 5
      assert eval_in("jank.accept.ifsome", "(if-some [x nil] x :none)") == :none
      # false is not nil, so it binds
      assert eval_in("jank.accept.ifsome", "(if-some [x false] x :none)") == false
    end

    test "when-some runs its body only when the test is non-nil" do
      load_slice("slice_35_when_some.bl", "jank.accept.whensome")
      assert eval_in("jank.accept.whensome", "(when-some [x 5] (* x 2))") == 10
      assert eval_in("jank.accept.whensome", "(when-some [x nil] (* x 2))") == nil
    end

    test "repeatedly builds a lazy sequence of thunk calls" do
      load_slice("slice_36_repeatedly.bl", "jank.accept.repeatedly")
      assert eval_in("jank.accept.repeatedly", """
             (def c (atom 0))
             (take 3 (repeatedly (fn [] (swap! c inc))))
             """) == [1, 2, 3]
    end

    test "take-while takes the prefix while pred holds (coll arity)" do
      load_slice("slice_37_take_while.bl", "jank.accept.takewhile")
      # take-while returns a lazy seq; compare readably
      assert eval_in("jank.accept.takewhile", "(pr-str (take-while pos? [1 2 3 -1]))") == "(1 2 3)"
    end

    test "drop-while drops the prefix while pred holds (coll arity)" do
      load_slice("slice_38_drop_while.bl", "jank.accept.dropwhile")
      assert eval_in("jank.accept.dropwhile", "(pr-str (drop-while pos? [1 2 -1 3]))") == "(-1 3)"
    end

    test "split-at returns a vector of take and drop" do
      load_slice("slice_39_split_at.bl", "jank.accept.splitat")
      assert eval_in("jank.accept.splitat", "(split-at 2 [1 2 3 4 5])") ==
               BeamLisp.Vector.new([[1, 2], [3, 4, 5]])
    end

    test "interleave merges colls positionally (2-arity docstring example)" do
      load_slice("slice_40_interleave.bl", "jank.accept.interleave")
      assert eval_in("jank.accept.interleave", "(pr-str (interleave [1 2 3] [:a :b :c]))") ==
               "(1 :a 2 :b 3 :c)"
    end

    test "update applies f to a key's value" do
      load_slice("slice_47_update.bl", "jank.accept.update")
      assert eval_in("jank.accept.update", "(update {:a 1} :a inc)") == %{a: 2}
      assert eval_in("jank.accept.update", "(update {} :a (fn [x] 0))") == %{a: 0}
      assert eval_in("jank.accept.update", "(update {:a 1} :a + 10)") == %{a: 11}
    end

    test "mapcat concatenates the mapped results (coll arity)" do
      load_slice("slice_48_mapcat.bl", "jank.accept.mapcat")
      assert eval_in("jank.accept.mapcat", "(mapcat (fn [x] [x x]) [1 2])") == [1, 1, 2, 2]
    end

    test "remove filters out the items pred accepts" do
      # remove is (filter (complement pred)) upstream, so it needs the
      # `complement` slice co-loaded (core.jank's own dependency).
      load_slice("slice_03_complement.bl", "jank.accept.remove")
      load_slice("slice_51_remove.bl", "jank.accept.remove")
      assert eval_in("jank.accept.remove", "(remove even? [1 2 3 4 5 6])") == [1, 3, 5]
    end

    test "assoc-in sets a value at a nested path" do
      # These two hung before an exhausted `& rest` bound nil: upstream
      # recurs while `ks` is truthy, and an empty collection is truthy.
      load_slice("slice_45_assoc_in.bl", "jank.accept.associn")
      assert eval_in("jank.accept.associn", "(assoc-in {:a {:b 1}} [:a :b] 9)") == %{a: %{b: 9}}
      assert eval_in("jank.accept.associn", "(assoc-in {} [:a] 1)") == %{a: 1}
    end

    test "update-in applies a fn at a nested path" do
      load_slice("slice_45_assoc_in.bl", "jank.accept.updatein")
      load_slice("slice_46_update_in.bl", "jank.accept.updatein")
      assert eval_in("jank.accept.updatein", "(update-in {:a {:b 1}} [:a :b] inc)") ==
               %{a: %{b: 2}}
    end

    # --- wave 17: transients, and the seq layer under the threading
    # macros. partition exposed three seq bugs on the way in: count on
    # a lazy seq counted struct fields, next returned an unforced tail
    # so an exhausted seq was truthy, and Inspect crashed outright.

    test "partition splits into non-overlapping groups" do
      load_slice("slice_41_partition.bl", "jank.accept.partition")
      assert eval_in("jank.accept.partition", "(doall (partition 2 [1 2 3 4]))") == [[1, 2], [3, 4]]
      # a trailing group smaller than n is dropped, as in Clojure
      assert eval_in("jank.accept.partition", "(doall (partition 2 [1 2 3]))") == [[1, 2]]
      assert eval_in("jank.accept.partition", "(doall (partition 2 3 [1 2 3 4 5 6]))") ==
               [[1, 2], [4, 5]]
    end

    test "cond-> threads only through the forms whose test is true" do
      load_slice("slice_41_partition.bl", "jank.accept.condarrow")
      load_slice("slice_53_cond_arrow.bl", "jank.accept.condarrow")
      assert eval_in("jank.accept.condarrow", "(cond-> 5 true inc)") == 6
      assert eval_in("jank.accept.condarrow", "(cond-> 5 false inc)") == 5
      # unlike cond, it does not stop at the first true test
      assert eval_in("jank.accept.condarrow", "(cond-> 5 true inc true inc)") == 7
    end

    test "cond->> threads through the last argument position" do
      load_slice("slice_41_partition.bl", "jank.accept.condarrowlast")
      load_slice("slice_54_cond_arrow_last.bl", "jank.accept.condarrowlast")
      assert eval_in("jank.accept.condarrowlast", "(cond->> 5 true (- 8))") == 3
    end

    test "as-> binds the threaded value to a name" do
      load_slice("slice_55_as_arrow.bl", "jank.accept.asarrow")
      assert eval_in("jank.accept.asarrow", "(as-> 5 x (+ x 1) (* x 2))") == 12
    end

    test "some-> and some->> stop at the first nil" do
      load_slice("slice_56_some_arrow.bl", "jank.accept.somearrow")
      assert eval_in("jank.accept.somearrow", "(some-> 5 inc)") == 6
      assert eval_in("jank.accept.somearrow", "(some-> nil inc)") == nil

      load_slice("slice_57_some_arrow_last.bl", "jank.accept.somearrowlast")
      assert eval_in("jank.accept.somearrowlast", "(some->> 5 (- 8))") == 3
      assert eval_in("jank.accept.somearrowlast", "(some->> nil (- 8))") == nil
    end

    test "assert passes silently and throws on a false test" do
      load_slice("slice_64_assert.bl", "jank.accept.assert")
      assert eval_in("jank.accept.assert", "(assert true)") == nil

      assert eval_in("jank.accept.assert", "(try (assert false) :no-throw (catch e :threw))") ==
               :threw
    end

    test "keys and vals walk the map through a transient" do
      # Upstream builds a vector with transient/conj!/persistent! and
      # seqs it — its own TODO says "use a proper key seq instead" — so
      # a vector result is faithful to this code.
      load_slice("slice_26_keys.bl", "jank.accept.keys")
      assert eval_in("jank.accept.keys", "(count (keys {:a 1 :b 2}))") == 2
      assert eval_in("jank.accept.keys", "(keys {})") == nil

      load_slice("slice_27_vals.bl", "jank.accept.vals")
      assert eval_in("jank.accept.vals", "(count (vals {:a 1 :b 2}))") == 2
    end

    test "zipmap, frequencies and group-by build maps with transients" do
      load_slice("slice_29_zipmap.bl", "jank.accept.zipmap")
      assert eval_in("jank.accept.zipmap", "(zipmap [:a :b] [1 2])") == %{a: 1, b: 2}

      load_slice("slice_42_frequencies.bl", "jank.accept.frequencies")
      assert eval_in("jank.accept.frequencies", "(frequencies [:a :a :b])") == %{a: 2, b: 1}

      load_slice("slice_43_group_by.bl", "jank.accept.groupby")

      assert eval_in("jank.accept.groupby", "(get (group-by even? [1 2 3 4]) true)") ==
               BeamLisp.Vector.new([2, 4])
    end

    test "max-key returns the x with the greatest (k x)" do
      load_slice("slice_62_max_key.bl", "jank.accept.maxkey")
      assert eval_in("jank.accept.maxkey", "(max-key count [1 2 3] [4] [5 6])") ==
               BeamLisp.Vector.new([1, 2, 3])
    end

    test "min-key returns the x with the least (k x)" do
      # This one was blocked by a link bug, not a missing feature:
      # `<=` linked to :erlang."<="/2, which does not exist — Erlang
      # spells it `=<`. The chained arity went through invoke and
      # worked, so only the 2-arity call failed.
      load_slice("slice_63_min_key.bl", "jank.accept.minkey")

      assert eval_in("jank.accept.minkey", "(min-key count [1 2 3] [4] [5 6])") ==
               BeamLisp.Vector.new([4])
    end
  end
end
