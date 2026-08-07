defmodule BeamLisp.SpecterCompatTest do
  # The thesis: Specter is beam-lisp's north star for optics. beam-lisp
  # ships its own optics in priv/optics.bl, but the settled question is
  # the honest one — how far is beam-lisp from running Clojure's Specter
  # as-is? Every fixture under test/fixtures/specter/ is a verbatim
  # block of the real Specter, copied with its sha256 in a header; the
  # harness wraps each in a throwaway `(ns …)` and evaluates it.
  #
  # ONLY slices that load AND behave correctly are tested here. A slice
  # that needs a local edit is a FAIL, recorded in docs/specter-compat.md,
  # never patched into passing. The measurement is 23 of 31 load, and
  # 4 of 31 load AND behave (slices 01, 02, 12, 16) — those four are
  # exercised here. The gap between loading and behaving is the point:
  # the syntax is mostly there, but Specter's impl machinery (i/NONE,
  # the compiled path cache, the exec interop) and a handful of missing
  # core prims are not. docs/specter-compat.md holds the full per-slice
  # table and the honest re-ranking.
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
  end
end
