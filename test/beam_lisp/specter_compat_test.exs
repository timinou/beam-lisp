defmodule BeamLisp.SpecterCompatTest do
  # The thesis: Specter is beam-lisp's north star for optics. beam-lisp
  # ships its own optics in priv/std/optics.bl, but the settled question is
  # the honest one — how far is beam-lisp from running Clojure's Specter
  # as-is? Every fixture under test/fixtures/specter/ is a verbatim
  # block of the real Specter, copied with its sha256 in a header; the
  # harness wraps each in a throwaway `(ns …)` and evaluates it.
  #
  # ONLY slices that load AND behave correctly are tested here. A slice
  # that needs a local edit is a FAIL, recorded in docs/specter-compat.md,
  # never patched into passing. The measurement (wave 28) is 25 of 31
  # load, and 9 of 31 load AND behave (slices 01, 02, 03, 04, 05, 12, 16,
  # 17, 31) — those nine are exercised here. Slice 05 (defnav/defrichnav)
  # is new this wave: its expansion needs `for`, `declare`, and `vary-meta`
  # variadic, all of which landed, so an empty-params defnav now constructs
  # a working navigator. The load number moved 23 → 25: slices 23 (ALL)
  # and 24 (MAP-VALS) — empty-params defnav callers — now load too. The
  # remaining load failures (11, 15, 25, 26, 27, 29) are Specter-internal
  # (i/direct-nav-obj, n/PosNavigator, eachnav, srange-transform*) or a
  # correct reader-conditional miss (29). The gap between loading and
  # behaving is the point: what remains is Specter's impl machinery
  # (i/NONE, the compiled path cache, the exec interop, .select* host
  # dispatch) rather than beam-lisp core forms. docs/specter-compat.md
  # holds the full per-slice table and the honest re-ranking.
  use ExUnit.Case, async: false

  @moduletag :specter_compat

  # Provenance of the vendored source — src/clj/com/rpl/specter/* in
  # https://github.com/redplanetlabs/specter at commit
  # 6119462a4d959834f2d78a6183d74608bf08ab52. License Apache-2.0.
  @commit "6119462a4d959834f2d78a6183d74608bf08ab52"

  # All vendored fixtures: {fixture, upstream-file, start-line, end-line,
  # sha256-of-code-portion}. The sha256 is of the fixture with its `;`
  # header comments removed — i.e. exactly the upstream text (the `(ns …)`
  # header line is excluded because the harness provides its own). If any
  # fixture drifts from upstream, the checksum test below fails and the
  # fidelity claim is void. Every fixture is vendored and checksummed;
  # only the ones that genuinely load AND behave are additionally
  # exercised as tests.
  @fixtures [
    {"01_rich_navigator_protocol", "protocols.cljc", 3, 18,
     "e4c40a7ba3c73bbd07e9a636b8bc95be1a70c29cbddc9bd2eba936136b12e243"},
    {"02_collector_implicitnav", "protocols.cljc", 21, 27,
     "7ff3b4873d36a0e8ccf6b91006653b4e611f0869575ce6abf9c5332ee72b238c"},
    {"03_determine_params_impls", "macros.clj", 6, 11,
     "66080e990590d5bf800d3e7105e8611cb135d472b2363517f0d165bf329ca9f0"},
    {"04_richnav_nav", "macros.clj", 14, 32,
     "8ee194989f4b2ecd349b4325d5e1d8f120480282da48aa582ded61887845d2cf"},
    {"05_defnav_defrichnav", "macros.clj", 34, 54,
     "c9166d97416ee606f14ea12b6b5e2df8fdf230b4f2b510b301bcdf3134416755"},
    {"06_not_selected_selected", "navs.cljc", 15, 23,
     "d16cb64751d4c996dbe7cfa4448bfc6c19e2708f696d5445248a651025a16284"},
    {"07_all_select", "navs.cljc", 26, 28,
     "94c71f921eaa2316e8634d3e5936e99ee5364da0d45ec18a20ac4de02e12424f"},
    {"08_queue_reader_cond", "navs.cljc", 30, 37,
     "b909eb1633e111ac1744e6ff2d57726b9d0541f455973ac29f7c8e2900e2af53"},
    {"09_void_kv_pair_non_transient", "navs.cljc", 43, 55,
     "22666b5d5f40d2a4dde85e6efdd711bda8bf7c34c0b78ecf7dc1d0c61f5a02de"},
    {"10_not_none_all_transform", "navs.cljc", 57, 69,
     "2074ce26c74dfac4035f926967fd5f5dcdf5e540c3094a70f2428efe47bad277"},
    {"11_srange_select", "navs.cljc", 395, 402,
     "00c75d82b987067997735624c7e3d0c32d4afa03d61a45bbbacb5f972461f023"},
    # ── the one genuinely-behaving slice (PASS): a pure function over
    # path shapes that needs only fn?/coll?/every?/reduce/and/cond.
    {"12_extract_basic_filter_fn", "navs.cljc", 405, 418,
     "b699615701bee06988836eb5b1375d4386b11917cba61ecef09f7004fbed7f32"},
    {"13_if_select_if_transform", "navs.cljc", 421, 437,
     "2c32d8ab716268c8d0bff75f1cb8acbbbfd5f7719f696f20a2e21abd57dee405"},
    {"14_do_keypath_transform", "navs.cljc", 689, 695,
     "96a6576fb9a6eb728dadb2d312b2f428e3c4f29e6caebc364836c3e213f84f2c"},
    {"15_keypath_must_richnav", "navs.cljc", 697, 721,
     "09a5aa2faa41b776d9d9e85ebf609af3ea0e239d9ae48934be1c1d3cba194ed8"},
    {"16_insert_before_index_list", "navs.cljc", 755, 758,
     "bbe6e3b3c0097800b151e9c3b513087a725323bbe0faea9974bf994d95c91fd4"},
    {"17_static_path_wrap_dynamic", "specter.cljc", 35, 53,
     "ad1a92a538d1b0267eb0bc85b1c0226ed09711ea89494a342bc7bb73b7167a1a"},
    {"18_select_macro", "specter.cljc", 349, 354,
     "30467290557dccf14885166b7d6937e275116aef5abd737f01fa30ee3de0a8b1"},
    {"19_select_any_macro", "specter.cljc", 373, 379,
     "fea20380e7e5fb737e4b242d0bd191ac715ce79909d127656fd80433a7447a43"},
    {"20_transform_macro", "specter.cljc", 386, 392,
     "e9aa9757b697e0dc6a6531449f69b5937567cc6e50774674002c0da68ed01c7d"},
    {"21_setval_macro", "specter.cljc", 409, 413,
     "adac7a5e44288185c825eef5be1ace9356b15c44d3bcc7859a953a972c81f46c"},
    {"22_comp_paths", "specter.cljc", 516, 520,
     "20e846e0483f5b93836adc729b13fb6741580689594f48fe0f10f84c19b10712"},
    {"23_all_nav", "specter.cljc", 717, 725,
     "2b6f3e636e726afb3ddb2959d511f9192fb5fe1fdf3383c720205119e2b868ba"},
    {"24_map_vals_nav", "specter.cljc", 740, 749,
     "fc1e82d9be344d04e76b0841521dd12d3864462cc0d6f3707bc908b801635027"},
    {"25_first_last", "specter.cljc", 767, 777,
     "ff772b6230a2026a44aa1eccecf8aa0302671f439e165763e35cb26ec870072a"},
    {"26_srange_nav", "specter.cljc", 793, 801,
     "6b8dd83380534746ce6db6fe18c6f89ee4308093e5a7f5d68d49f516e6f117b1"},
    {"27_keypath_nav", "specter.cljc", 989, 993,
     "75a2c1a1b7b85ac9b5ce30e01c0df2212345b44994b28c4eefa699264a6513c8"},
    {"28_exec_select_transform", "impl.cljc", 99, 127,
     "45e05e83716f2e644b6f1c5f29ebb68e8da01a82c3fbe1eec02daea03b0a1409"},
    {"29_mutable_cell_deftype", "impl.cljc", 222, 273,
     "906af3f92edfab8bec0279294378820f475b37835f6243ad58b54d00dbea988a"},
    {"30_compiled_select_transform", "impl.cljc", 372, 441,
     "3ceb3310eb84101c5e6d4fa4027ec6322b2d76dbc7e6b39fb71059fe2ef55f24"},
    {"31_defrecord_path_forms", "impl.cljc", 449, 474,
     "bef96fb03ded685919a9ca428233b7819ae4853eea1c22f2c358fce7ebd72e67"}
  ]

  setup_all do
    BeamLisp.init()
    :ok
  end

  # The fixture minus its provenance header. The header lines all begin
  # with `;`; the slice text itself is the upstream defn/defmacro forms.
  defp fixture_code(fixture) do
    Path.join(["test", "fixtures", "specter", "slice_#{fixture}.bl"])
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
    for {fixture, _file, _start, _end, expected} <- @fixtures do
      actual = :crypto.hash(:sha256, fixture_code(fixture)) |> Base.encode16(case: :lower)

      assert actual == expected,
             "#{fixture} drifts from upstream specter@#{@commit} — the fidelity claim is void"
    end
  end

  describe "verbatim specter slices" do
    test "extract-basic-filter-fn normalizes a filter path into a predicate" do
      # A path shape — either a single predicate or a collection of
      # predicates ANDed together — becomes one predicate. Upstream
      # uses it to compile `(filterer …)`-style filter paths.
      load_slice("12_extract_basic_filter_fn", "specter.accept.extractfilter")

      # a bare fn is returned unchanged
      assert eval_in("specter.accept.extractfilter", "((extract-basic-filter-fn odd?) 3)") == true
      assert eval_in("specter.accept.extractfilter", "((extract-basic-filter-fn odd?) 2)") == false

      # a collection of fns is reduced into the AND of them all
      assert eval_in("specter.accept.extractfilter", "((extract-basic-filter-fn [odd? pos?]) 3)") ==
               true

      assert eval_in("specter.accept.extractfilter", "((extract-basic-filter-fn [odd? pos?]) -3)") ==
               false
    end

    test "rich-navigator protocol defines and dispatches a working navigator protocol" do
      # A defprotocol with a leading docstring and per-method docstrings. Its
      # behavior is that it can be implemented (here via reify) and its methods
      # dispatched — the docstring support is what used to block this slice
      # from loading at all, and the protocol itself now works end to end.
      load_slice("01_rich_navigator_protocol", "specter.accept.richnav")

      # both methods reify'd onto one instance and dispatch correctly
      assert eval_in(
               "specter.accept.richnav",
               "(let [nav (reify RichNavigator" <>
                 " (select* [this vals structure next-fn] (next-fn vals structure))" <>
                 " (transform* [this vals structure next-fn] (+ structure 1)))]" <>
                 " [(select* nav [] 41 (fn [vals s] (+ s 1)))" <>
                 "  (transform* nav [] 41 (fn [vals s] s))])"
             ) == BeamLisp.Vector.new([42, 42])
    end

    test "collector and implicit-nav protocols define and dispatch" do
      # Two more defprotocols, the second (ImplicitNav) without a docstring.
      # Both dispatch through reify — the single-arg implicit-nav dispatches on
      # its argument, the two-arg collect-val on its receiver + structure.
      load_slice("02_collector_implicitnav", "specter.accept.collector")

      assert eval_in(
               "specter.accept.collector",
               "(let [c (reify Collector (collect-val [this structure] (inc structure)))" <>
                 "      i (reify ImplicitNav (implicit-nav [obj] :ok))]" <>
                 " [(collect-val c 41) (implicit-nav i)])"
             ) == BeamLisp.Vector.new([42, :ok])
    end

    test "insert-before-index-list inserts a value at an index into a seq" do
      # A defn- (private) list-insertion helper — the first thing the old
      # measurement couldn't even parse, now both private and functional.
      load_slice("16_insert_before_index_list", "specter.accept.insertidx")

      assert BeamLisp.Test.realize(
               eval_in(
                 "specter.accept.insertidx",
                 "(insert-before-index-list [1 2 3 4] 2 :x)"
               )
             ) == [1, 2, :x, 3, 4]

      # index 0 pushes to the front; end-of-list appends
      assert BeamLisp.Test.realize(eval_in("specter.accept.insertidx", "(insert-before-index-list [1 2] 0 :z)")) ==
               [:z, 1, 2]

      assert BeamLisp.Test.realize(eval_in("specter.accept.insertidx", "(insert-before-index-list [1 2] 2 :y)")) ==
               [1, 2, :y]
    end

    test "determine-params-impls groups method impls into a method-name keyed map" do
      # The `nav` macro's destructure-input: a list of `(method params body…)`
      # forms becomes a map `{'select* …, 'transform* …}`. Newly behaving
      # because `into` and `keys` landed in wave 27's prim batch.
      load_slice("03_determine_params_impls", "specter.accept.detparams")

      # both methods are present as symbol keys, each holding params+body
      assert eval_in(
               "specter.accept.detparams",
               "[(= (set (list 'select* 'transform*))" <>
                 " (set (keys (determine-params-impls" <>
                 " '((select* [a] b) (transform* [c] d))))))" <>
                 "  (count (get (determine-params-impls" <>
                 " '((select* [a] b) (transform* [c] d))) 'select*))]"
             ) == BeamLisp.Vector.new([true, 2])
    end

    test "nav/richnav macros build a working navigator (empty params -> reify path)" do
      # Wave 27's headline fix: the `nav` macro destructures its impls on a
      # literal quoted-symbol key `'select*`. That now parses, so `nav` can
      # expand into `richnav` -> `(reify RichNavigator …)`. Co-loaded with its
      # two vendored deps (RichNavigator protocol + determine-params-impls),
      # a navigator built by `nav` selects and transforms end to end.
      # (The non-empty-params path still needs the non-vendored
      # `i/direct-nav-obj`, so only the empty-params half is asserted.)
      env = BeamLisp.Compiler.new_env("specter.accept.navstack")

      src =
        "(ns specter.accept.navstack)\n" <>
          fixture_code("01_rich_navigator_protocol") <>
          "\n" <>
          fixture_code("03_determine_params_impls") <>
          "\n" <>
          fixture_code("04_richnav_nav")

      BeamLisp.Compiler.eval_string(src, env)

      result =
        BeamLisp.Compiler.eval_string(
          "(ns specter.accept.navstack)\n" <>
            "(let [nv (nav [] (select* [this structure next-fn] (next-fn structure))\n" <>
            "                    (transform* [this structure next-fn] (inc structure)))]\n" <>
            "  [(select* nv [] 41 (fn [vals s] (+ s 1)))\n" <>
            "   (transform* nv [] 41 (fn [vals s] s))])",
          env
        )

      assert result == BeamLisp.Vector.new([42, 42])
    end

    test "defnav/defrichnav macros build a navigator (empty params, for+vary-meta+declare path)" do
      # The full macro-stack payoff: defnav and defrichnav now *expand*. Co-loaded
      # with their vendored deps (RichNavigator, determine-params-impls, nav/richnav),
      # an empty-params `defnav`/`defrichnav` constructs a navigator that dispatches
      # select*/transform* end to end. Newly behaving this wave because defnav's body
      # needs `for` (helpers), `declare` (forward decls), and `vary-meta` variadic
      # (the :arglists stamp) — all three landed. The empty-params path is the half
      # that avoids `i/direct-nav-obj` (non-vendored), so only it is asserted.
      env = BeamLisp.Compiler.new_env("specter.accept.defnavstack")

      src =
        "(ns specter.accept.defnavstack)\n" <>
          fixture_code("01_rich_navigator_protocol") <>
          "\n" <>
          fixture_code("03_determine_params_impls") <>
          "\n" <>
          fixture_code("04_richnav_nav") <>
          "\n" <>
          fixture_code("05_defnav_defrichnav")

      BeamLisp.Compiler.eval_string(src, env)

      result =
        BeamLisp.Compiler.eval_string(
          "(ns specter.accept.defnavstack)\n" <>
            "(defnav probeALL []\n" <>
            "  (select* [this structure next-fn] (next-fn structure))\n" <>
            "  (transform* [this structure next-fn] (inc structure)))\n" <>
            "(defrichnav probeR []\n" <>
            "  (select* [this vals structure next-fn] (next-fn vals structure))\n" <>
            "  (transform* [this vals structure next-fn] (inc structure)))\n" <>
            "[(select* probeALL [] 41 (fn [v s] (+ s 1)))\n" <>
            " (transform* probeALL [] 41 (fn [v s] s))\n" <>
            " (select* probeR [] 41 (fn [v s] (+ s 1)))\n" <>
            " (transform* probeR [] 41 (fn [v s] s))]",
          env
        )

      assert result == BeamLisp.Vector.new([42, 42, 42, 42])
    end

    test "dynamic-param? classifies the path-analyzer records via type" do
      # The path-analyzer records (LocalSym … DynamicFunction) plus a
      # predicate over their `type`. Newly behaving because wave 27's `type`
      # returns the record's module, so `(contains? #{DynamicPath …} (type o))`
      # actually matches. A keyword/vector is not a dynamic-param.
      load_slice("31_defrecord_path_forms", "specter.accept.pathforms")

      assert eval_in(
               "specter.accept.pathforms",
               "[(dynamic-param? (->DynamicVal 'x))\n" <>
                 " (dynamic-param? (->DynamicPath [:a]))\n" <>
                 " (dynamic-param? (->DynamicFunction :f [] 'x))\n" <>
                 " (dynamic-param? (->LocalSym 'x 'y))\n" <>
                 " (dynamic-param? :a)]"
             ) == BeamLisp.Vector.new([true, true, true, false, false])
    end

    test "static-path? distinguishes static paths from dynamic-path records" do
      # static-path? (a private fn) recurses over a path; a leaf is static
      # unless `i/dynamic-param?` says it is a dynamic record. Co-loads slice
      # 31 into `com.rpl.specter.impl` (its canonical upstream home) and
      # aliases `i` to it, exactly as Specter's own namespaces do. Newly
      # behaving because `type` now drives `dynamic-param?` correctly.
      env = BeamLisp.Compiler.new_env("specter.accept.pathcheck")

      BeamLisp.Compiler.eval_string(
        "(ns com.rpl.specter.impl)\n" <> fixture_code("31_defrecord_path_forms"),
        env
      )

      BeamLisp.Compiler.eval_string(
        "(ns com.rpl.specter (:require [com.rpl.specter.impl :as i]))\n" <>
          fixture_code("17_static_path_wrap_dynamic"),
        env
      )

      assert BeamLisp.Compiler.eval_string(
               "(ns com.rpl.specter)\n" <>
                 "[(static-path? :a)\n" <>
                 " (static-path? [:a :b])\n" <>
                 " (static-path? [])\n" <>
                 " (static-path? (i/->DynamicVal 'x))\n" <>
                 " (static-path? [(i/->DynamicVal 'x)])]",
               env
             ) == BeamLisp.Vector.new([true, true, true, false, false])
    end
  end
  describe "verbatim slices running on beam-lisp's ported engine" do
    # Wave 28 ported Specter's compiled-path engine (priv/std/specter/*.bl).
    # These slices are the payoff and the proof: upstream's OWN code,
    # byte-for-byte, executing against our NONE, our doseqres and our
    # compiled-select-any*. A slice here is not "loads" — it computes a
    # verified answer.
    #
    # The engine is published under com.rpl.specter.impl, which is where
    # a vendored slice's `i/` alias points. That is the honest wiring:
    # the fixture is not adapted to us, we are adapted to it.
    defp with_engine(fixture, ns) do
      env = BeamLisp.Compiler.new_env(ns)

      BeamLisp.Compiler.eval_string(
        "(ns com.rpl.specter.impl (:require [specter.engine :refer :all] " <>
          "[specter.exec :refer :all]))",
        env
      )

      BeamLisp.Compiler.eval_string(
        "(ns #{ns} (:require [com.rpl.specter.impl :as i] " <>
          "[specter.engine :refer :all] [specter.exec :refer :all] " <>
          "[specter.navs :refer :all]))\n" <>
          fixture_code(fixture),
        env
      )

      env
    end

    test "slice 07: all-select folds with doseqres, honouring NONE and reduced" do
      # Upstream's all-select is three lines that exercise the whole
      # reduction contract: a NONE result must not clobber a sibling's,
      # and a reduced result must terminate the walk.
      env = with_engine("07_all_select", "specter.engine.allselect")

      ev = fn src ->
        BeamLisp.Compiler.eval_string("(ns specter.engine.allselect)\n" <> src, env)
      end

      # every element reaches next-fn, in order
      assert ev.("(let [acc (volatile! [])] " <>
                   "(all-select [1 2 3] (fn [e] (vswap! acc conj e) i/NONE)) @acc)") ==
               BeamLisp.Vector.new([1, 2, 3])

      # all-NONE stays NONE, rather than degrading to nil or []
      assert ev.("(i/none? (all-select [1 2 3] (fn [e] i/NONE)))") == true

      # a non-NONE result wins over the NONEs around it
      assert ev.("(all-select [1 2 3] (fn [e] (if (= e 2) :hit i/NONE)))") == :hit

      # reduced short-circuits: only two of five elements are visited
      assert ev.("(let [n (volatile! 0)] " <>
                   "(all-select [1 2 3 4 5] " <>
                   "(fn [e] (vswap! n inc) (if (= e 2) (reduced e) i/NONE))) @n)") == 2

      # an empty structure selects nothing
      assert ev.("(i/none? (all-select [] (fn [e] e)))") == true
    end

    test "slice 06: selected?* answers through compiled-select-any*" do
      # This slice found a genuine gap: it calls the 3-arity
      # compiled-select-any* that threads `vals`, and the port had only
      # the 2-arity form. Measuring against real code is what surfaced
      # it — the hand-written tests all used the arity we had written.
      env = with_engine("06_not_selected_selected", "specter.engine.selected")

      ev = fn src ->
        BeamLisp.Compiler.eval_string("(ns specter.engine.selected)\n" <> src, env)
      end

      assert ev.("(selected?* (i/comp-paths* [:a]) [] {:a 1})") == true
      assert ev.("(not-selected?* (i/comp-paths* [:a]) [] {:a 1})") == false

      # a path that navigates nowhere is not selected
      assert ev.("(selected?* (i/comp-paths* [(pred* odd?)]) [] 2)") == false
      assert ev.("(not-selected?* (i/comp-paths* [(pred* odd?)]) [] 2)") == true
    end

    test "slice 14: do-keypath-transform rebuilds the map around the new value" do
      env = with_engine("14_do_keypath_transform", "specter.engine.keypath")

      ev = fn src ->
        BeamLisp.Compiler.eval_string("(ns specter.engine.keypath)\n" <> src, env)
      end

      assert ev.("(do-keypath-transform [] {:a 1} :a (fn [vals v] (inc v)))") == %{a: 2}

      # everything not navigated to is left exactly as it was
      assert ev.("(do-keypath-transform [] {:a 1 :b 9} :a (fn [vals v] (inc v)))") ==
               %{a: 2, b: 9}
    end
  end

end
