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
     "32026ae941ec5598e27b64584ff7e3c7f7d9818d5a06c274ec1a5c844dfbf40e"},
    # Unlocked by `:as` in sequential destructuring.
    {"slice_52_condp.bl", "jank.accept.condp",
     "a724c9bb3ed6db0a5c1546c0aa208f7f394534345ced2c178fcc930a24bb53e0"},
    # Wave 18: a set type + `#{}` reader literal + transient sets,
    # sort/compare, seq over a map, the cpp/* primitive shim, and
    # normalizing any seqable a lazy-seq body returns.
    {"slice_28_select_keys.bl", "jank.accept.selectkeys",
     "d4f9c3f2a838fd02b30730cc0cd9a21950e297c1f0d37422a42ded04724e9340"},
    {"slice_30_set.bl", "jank.accept.set",
     "4180ab891c473b2325924980095b1a19ddcc5de36c5a15bdefdcf774a92001ab"},
    {"slice_31_name.bl", "jank.accept.name",
     "82ab2f373d41947b993ef55347a3a7c72d7fb580bf5e187edbedba258190744a"},
    {"slice_32_namespace.bl", "jank.accept.namespace",
     "530f6530966826824a6d5568cd25c8d7b593e9325e194c73b439b75cca908de2"},
    {"slice_33_keyword.bl", "jank.accept.keyword",
     "4e43d1673667d674c28d2c63b9837e41521d92323b55b6d510876767f529fbf4"},
    {"slice_40_interleave.bl", "jank.accept.interleave",
     "a4063bb35431e45f546c18046227b5897401effffd8281c6601e7645b1a9e29b"},
    {"slice_49_distinct.bl", "jank.accept.distinct",
     "4eae4d2d16e8a93fcbc43564645f8c699172f61c2186fe39ed16f6ef2fcf6f50"},
    {"slice_50_flatten.bl", "jank.accept.flatten",
     "121aa2312d80a204833dd835d96157ba05106c227bfa53af9e0278e94e94eccd"},
    {"slice_58_merge_with.bl", "jank.accept.mergewith",
     "5985edd900e3b27b00f2a399178f6c996b30c44d8cad6069cbb83b2f074bb89d"},
    {"slice_59_sort_by.bl", "jank.accept.sortby",
     "6da8e42409ae1f55ebd576ef4e162cb6aa96e9499321f26f21033ef934bc2262"},
    # Promoted by wave 23. `for` was the last real compiler gap in the
    # sample: its signature destructures a rest argument that is itself
    # a pattern, which split_variadic/1 refused. It also needed the
    # lazy-seq thunk fix (its emits nest concat inside lazy-seq) and
    # when-first in core. Three unrelated-looking bugs, one fixture.
    {"slice_44_for.bl", "jank.accept.for",
     "977712c0fb622d051d800f5ab9fba840ab065717112be7c03ad72f38f21cc437"},
    {"slice_61_lazy_cat.bl", "jank.accept.lazycat",
     "cc8202e3f4a02c8a39f089ef85a608c88bb04b0923380f604dc2a7e3c03f1efc"},
    # Promoted by wave 24 (widen-the-sample, third). The reduce/transducer
    # family, the pure tail-of-file seq fns, and the numeric predicates.
    # The transducer arities are measured honestly: collection arities
    # behave, 1-arity transducer paths that need volatile!/reduced are
    # recorded in docs/jank-compat.md and NOT promoted here.
    {"slice_70_reduce.bl", "jank.accept.reduce",
     "19370610dd18dfc6f3b71b8d27d2506f8d03b66cd74cdbbacda221bc9a5117e4"},
    {"slice_71_completing.bl", "jank.accept.completing",
     "a5e6ecef044a21661c0aea43d9ded8c9532d57eb76ca46bba324dac02cb7f306"},
    {"slice_79_not_eq.bl", "jank.accept.noteq",
     "dc80a0e6ead5dfde546b6d03097be256a3fd58341dade7305fd10eb5184b25ef"},
    {"slice_84_signed_int_preds.bl", "jank.accept.posint",
     "6eafad4fc3d1a3487608466aae284c02f5a7bf2608cb73d1d23a56c3ac6f3304"},
    {"slice_86_nthnext.bl", "jank.accept.nthnext",
     "d2b4c5ff91f95992f17490d107d1cd098b5aff2df430a6b6cd70a3a496ac06d9"},
    {"slice_87_nthrest.bl", "jank.accept.nthrest",
     "98a16c9c55ca013356cef874a616a99378766046c3d358e3cba6a3cb23b0d80c"},
    {"slice_88_take_nth.bl", "jank.accept.takenth",
     "12bd2618c253513c0dbb1912e66a60f33963265ed21f2c2b4f30cb915c081ec0"},
    {"slice_89_map.bl", "jank.accept.map",
     "97125e0f2de8de29286a0df446fda42779517990bdf52538df9003e03c00c5cb"},
    {"slice_90_map_indexed.bl", "jank.accept.mapindexed",
     "bdbdaf048b0533d9c3537b9aa5d84bd0598be718fd2d77ac74ffbeca17e1ce1e"},
    {"slice_91_keep.bl", "jank.accept.keep",
     "92484f163ff7e7b1d97f0b81e238378c27c04d42296fc4844d77ffc924cf587d"},
    {"slice_92_keep_indexed.bl", "jank.accept.keepindexed",
     "f1c9ca7031538c7ceef097f27c5f9f25ae28e61243005cdde782549e2f336977"},
    {"slice_94_split_with.bl", "jank.accept.splitwith",
     "db601d03d8347a1178cc43b41d21412cc38c4b2f539c57d39dbf3e11b323854a"},
    {"slice_96_dorun.bl", "jank.accept.dorun",
     "8e16dd25ff37c8b104a7caf105e0a000764b35d58c37bb3e20af2117bd670666"},
    {"slice_97_doall.bl", "jank.accept.doall",
     "03e7ef8c1157f7503f1ab9fa42f69ebce2490ef4b88b14db8e66cd8079685137"},
    {"slice_100_take_last.bl", "jank.accept.takelast",
     "6c612e02038efa17254f2c3f188ce074aa852f56473c6e6279c0ade845588735"},
    {"slice_101_mapv.bl", "jank.accept.mapv",
     "1df3d96917e8d546bb67e9788981942e216f8c22ed206a32127b79bf93742c43"},
    {"slice_102_filterv.bl", "jank.accept.filterv",
     "ffb187a6abd250022ab6755e95faab56fedabc563d3665b367b3d201668a0a83"},
    {"slice_103_distinct_q.bl", "jank.accept.distinctq",
     "1de4563d8d85bbb5757b8f1870195d3975ae7641145fda7dcaacb76ea3dc7af5"},
    {"slice_104_filter.bl", "jank.accept.filter",
     "387bec70616ec2d9accf9171a53b27839c3f7c657acf09eb12b02e8d8fc6460a"},
    {"slice_105_dedupe.bl", "jank.accept.dedupe",
     "76be6684e8612d9991c00bd7d0c8b0e0ddc9051a05c6982868e731b8e47e5ded"},
    {"slice_106_nfirst.bl", "jank.accept.nfirst",
     "e2c6e082d68ab47d54d714db297a9dacd75b6f80028c148b5843f8c9e6eb290b"},
    {"slice_107_fnext.bl", "jank.accept.fnext",
     "17c620149059b65f11b4acb02abadf38e51c7961a1d6c903d4b2df76e3964a52"},
    {"slice_109_map_entry_q.bl", "jank.accept.mapentryq",
     "07de9dba71d58aa54fc2fa1349a314171c79c6c3a9ab61d11f45c015169b46f5"},
    {"slice_111_not_every_q.bl", "jank.accept.noteveryq",
     "db66d14bb2330bbc5c78af7d747532257409a7243e9db7608cd43696cf775bd6"},
    {"slice_112_replicate.bl", "jank.accept.replicate",
     "eaeb33657018c7c33df57a7ba4c7e0c3f93a9bfbf76aca0a952280eab1d51e48"},
    {"slice_113_comparator.bl", "jank.accept.comparator",
     "4521c68e92514c724bcb8e56106ac91cb32c3a3940078473765f4d60fcd53237"},
    # Promoted by wave 25 (re-measure after the cpp/jank.runtime shim
    # widened, the reader `^{}`-metadata fix, and volatile!/vreset!/vswap!
    # landed). 20 previously-failing slices now load AND behave. The
    # cpp shim gained reduce/reduced/is_reduced/peek/pop/promoting_inc and
    # the is_* predicates; the reader gained `^{:arglists …}` / `^{:inline …}`;
    # `volatile!` completed the transducer 1-arities. Slices that need a
    # co-loaded dependency name it (drop-last needs the vendored multi-coll
    # `map`; interpose needs `interleave`; transduce/cat need the transducer
    # machinery) — all core.jank's own, satisfied verbatim.
    {"slice_65_meta_def.bl", "jank.accept.listq",
     "7193e5ba85d94a04f52f3046a8bc18e08505909a2ff7bdae3d9aa6b004a9b7ce"},
    {"slice_66_reduced.bl", "jank.accept.reduced",
     "9cdb4b1510d8f51cd5fbc884ad525b77e7465bd06cbf7979fe4c856be615dab9"},
    {"slice_67_reduced_q.bl", "jank.accept.reducedq",
     "e0fbc2945e3e2fdce9f266fa05f161474042af17aa947c3784078f982ce6ae4f"},
    {"slice_68_ensure_reduced.bl", "jank.accept.ensurereduced",
     "4ef81b6e46f67d79d503b31817924fb84d665f603cf997d84e68c34463d02e79"},
    {"slice_69_unreduced.bl", "jank.accept.unreduced",
     "d45e93a845ae29f33c1fcfa54a3f32807614417f015cb760d16631b911f6b072"},
    {"slice_72_transduce.bl", "jank.accept.transduce",
     "b768a3da247c01db6c9cfaa3cc8b026bd594f1de00011a3a48b1fc9fd7ed5a3f"},
    {"slice_73_preserving_reduced.bl", "jank.accept.preservingreduced",
     "c8dd3a4c8dcc5e1de2fa243f4f1a59fc306254f426dc7fdc21314af06c1620b7"},
    {"slice_74_cat.bl", "jank.accept.cat",
     "362b110108e954908b99120a048a436935a717307019cfc5916539c2d39dddd5"},
    {"slice_75_peek.bl", "jank.accept.peek",
     "f71aead05a6e6d766960fef46b5027d9c9dad155c2d9895d198737460a1e6439"},
    {"slice_76_pop.bl", "jank.accept.pop",
     "a1ca3e4932f5d84c98627a64be0f8572f9c2fe6f43353e62615ccc70f2b3fde7"},
    {"slice_77_volatile.bl", "jank.accept.volatile",
     "2b0c67ea98a99c4f8265120f5492f2324250370f15281a597659f026d9e2d07f"},
    {"slice_81_promoting_arith.bl", "jank.accept.promoting",
     "9a06952e8fe518ca2e017e6f24c365a4d289082ac344833f543fdc9606b73b45"},
    {"slice_83_int_q.bl", "jank.accept.intq",
     "5e5e8a88d7dacb2c9d814d88256babf2be5a817839022de655d4ba35409cf948"},
    {"slice_93_drop_last.bl", "jank.accept.droplast",
     "fc3d5c6123383103a6917916038ef78161b5132b050743f763f1266f59c0838d"},
    {"slice_95_interpose.bl", "jank.accept.interpose",
     "fa6ab662f8d31dccb9890e33c58a060b95ca5151128590e35666ad4a8b3c124d"},
    {"slice_98_reductions.bl", "jank.accept.reductions",
     "b942e3c6048a6e784dd88e72dc6a7e5a09d0bf68d2a28a4334bb840974e59c52"},
    {"slice_99_into.bl", "jank.accept.into",
     "137470a3955d15d86263db032b01f47bf55d7997062ff93f562705d62f028bb6"},
    {"slice_114_ratio.bl", "jank.accept.ratio",
     "38ef42cbbb69e854eaba122d526595dc2142c02c29ae30d16a90c8bd75b5ab43"},
    {"slice_115_decimal_rational.bl", "jank.accept.decimal",
     "58c6bd7b68f97ec375794c60e77ccd1d9f89dd51f495fa015c7a00fcf638786a"},
    {"slice_116_sorted_preds.bl", "jank.accept.sorted",
     "1c095714c52d0fb864ad8c06f16d6a5516ce7fc2bc0c866b25cb509801885f8d"},
    {"slice_120_nan_q.bl", "jank.accept.nanq",
     "c0b22754c18091dd7bc134d803764bfa29b33b2b333d0a70fc64a95fad7fd0e4"},
    # Promoted by wave 26 (the core-gaps backlog). The small-prim gaps
    # the wave-25 re-measure named — `rem`, `float?`, `transientable?`,
    # `reduce-kv`, `bit_not` — plus `into`, multi-coll `map`, and
    # `take`'s transducer 1-arity were actually built. Eight of the nine
    # then-failing slices now load AND behave. `into` (slice 99) is the
    # exception: its vector/reduce and `take`-xform paths behave, but
    # `(into {} …)` throws (the map-transient `conj!` clause is missing)
    # and `(into [] (map inc) …)` throws (`map` still lacks its 1-arity
    # transducer form) — recorded in docs/jank-compat.md, NOT promoted.
    {"slice_78_bit_ops.bl", "jank.accept.bitnot",
     "a3526cc4e40a6c1e6dbc20a7c930f703f58f11077dd4a9e332d407ea23c95b63"},
    {"slice_80_mod.bl", "jank.accept.mod",
     "a294d54fcce083c581eb597500ef49299fbef7f70f86b2dd94ba97840f3ce890"},
    {"slice_85_double_q.bl", "jank.accept.doubleq",
     "b6351689e09567917469b8711b06f3faf5f3bada7a113fa12bc25b03729661d7"},
    {"slice_117_splitv_at.bl", "jank.accept.splitvat",
     "7c0414717303e587b15b81ec2277bf99aa8ec4526900f90867b448a0dc74e117"},
    {"slice_118_update_vals.bl", "jank.accept.updatevals",
     "231c6303bbda1e3d4c5733c183405c2865007fa7222cb83760df5c88c52c39a2"},
    {"slice_119_update_keys.bl", "jank.accept.updatekeys",
     "9cdffcd4664abbfc73d27002538ee30ccb82f9bb46434bed4abfa6dfcf5ee496"}
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

      assert eval_in("jank.accept.while", "(def c (atom 0)) (while (< @c 3) (swap! c inc)) @c") ==
               3
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
      assert eval_in("jank.accept.takewhile", "(pr-str (take-while pos? [1 2 3 -1]))") ==
               "(1 2 3)"
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
      # mapcat is `(apply concat (map …))` — uniformly lazy since wave 13,
      # so force it before comparing to a list.
      assert eval_in("jank.accept.mapcat", "(doall (mapcat (fn [x] [x x]) [1 2]))") ==
               [1, 1, 2, 2]
    end

    test "remove filters out the items pred accepts" do
      # remove is (filter (complement pred)) upstream, so it needs the
      # `complement` slice co-loaded (core.jank's own dependency).
      load_slice("slice_03_complement.bl", "jank.accept.remove")
      load_slice("slice_51_remove.bl", "jank.accept.remove")
      # remove is `(filter (complement pred))` — lazy since wave 13; force it.
      assert eval_in("jank.accept.remove", "(doall (remove even? [1 2 3 4 5 6]))") == [1, 3, 5]
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

      assert eval_in("jank.accept.partition", "(doall (partition 2 [1 2 3 4]))") == [
               [1, 2],
               [3, 4]
             ]

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

    test "condp dispatches through a binary predicate" do
      # condp calls split-at during macro expansion, so upstream's own
      # split-at slice has to share the namespace.
      load_slice("slice_39_split_at.bl", "jank.accept.condp")
      load_slice("slice_52_condp.bl", "jank.accept.condp")
      assert eval_in("jank.accept.condp", "(condp = 1 1 :one 2 :two)") == :one
      assert eval_in("jank.accept.condp", "(condp = 2 1 :one 2 :two)") == :two
      # a trailing odd form is the default
      assert eval_in("jank.accept.condp", "(condp = 9 1 :one :fallback)") == :fallback

      # and with no default, no matching clause throws
      assert eval_in(
               "jank.accept.condp",
               "(try (condp = 9 1 :one) :no-throw (catch e :threw))"
             ) == :threw
    end

    # --- wave 18: sets (type, `#{}` literal, transient sets), sort and
    # compare, seq over a map, the cpp/* primitive shim, and lazy-seq
    # bodies that return a bare collection rather than a cons cell.

    test "set builds a set through a transient and a set literal" do
      load_slice("slice_30_set.bl", "jank.accept.set")
      assert eval_in("jank.accept.set", "(count (set [1 2 2 3]))") == 3
      assert eval_in("jank.accept.set", "(contains? (set [1 2]) 2)") == true
    end

    test "distinct drops duplicates, keeping first-seen order" do
      load_slice("slice_49_distinct.bl", "jank.accept.distinct")
      assert eval_in("jank.accept.distinct", "(doall (distinct [1 1 2 3 3 1]))") == [1, 2, 3]
    end

    test "select-keys narrows a map" do
      load_slice("slice_28_select_keys.bl", "jank.accept.selectkeys")

      assert eval_in("jank.accept.selectkeys", "(select-keys {:a 1 :b 2 :c 3} [:a :c])") ==
               %{a: 1, c: 3}

      # a key that is not present is simply absent from the result
      assert eval_in("jank.accept.selectkeys", "(select-keys {:a 1} [:a :zz])") == %{a: 1}
    end

    test "name, namespace and keyword run on the cpp/* primitive shim" do
      # jank implements these with `(cpp/jank.runtime.…)` interop. We
      # cannot run C++, but we can register the same qualified names
      # backed by BEAM functions with the same semantics, which is
      # jank's own mechanism — so the vendored text loads unchanged.
      load_slice("slice_31_name.bl", "jank.accept.name")
      assert eval_in("jank.accept.name", "(name :foo)") == "foo"
      assert eval_in("jank.accept.name", ~S|(name "foo")|) == "foo"

      load_slice("slice_33_keyword.bl", "jank.accept.keyword")
      assert eval_in("jank.accept.keyword", ~S|(keyword "foo")|) == :foo
      assert eval_in("jank.accept.keyword", "(keyword :foo)") == :foo
    end

    test "merge-with combines colliding keys through a fn" do
      load_slice("slice_58_merge_with.bl", "jank.accept.mergewith")

      assert eval_in("jank.accept.mergewith", "(merge-with + {:a 1 :b 2} {:a 10})") ==
               %{a: 11, b: 2}
    end

    test "sort-by orders by a key fn" do
      load_slice("slice_59_sort_by.bl", "jank.accept.sortby")

      assert eval_in("jank.accept.sortby", "(doall (sort-by count [[1 2 3] [1] [1 2]]))") == [
               BeamLisp.Vector.new([1]),
               BeamLisp.Vector.new([1, 2]),
               BeamLisp.Vector.new([1, 2, 3])
             ]
    end

    test "flatten walks arbitrarily nested sequentials" do
      # flatten is (filter (complement sequential?) (rest (tree-seq …)))
      # so it needs upstream's own complement slice alongside it.
      load_slice("slice_03_complement.bl", "jank.accept.flatten")
      load_slice("slice_50_flatten.bl", "jank.accept.flatten")

      assert eval_in("jank.accept.flatten", "(doall (flatten [1 [2 [3 4]] 5]))") == [
               1,
               2,
               3,
               4,
               5
             ]
    end

    test "interleave and lazy-cat handle a lazy-seq over a bare collection" do
      # Both wrap a realized collection in (lazy-seq c), which used to
      # reach the seq walk as an opaque value and crash.
      load_slice("slice_40_interleave.bl", "jank.accept.interleave")

      assert eval_in("jank.accept.interleave", "(doall (interleave [1 2] [:a :b]))") == [
               1,
               :a,
               2,
               :b
             ]

      assert eval_in("jank.accept.interleave", "(doall (interleave [1 2]))") == [1, 2]
      # stops at the shorter input
      assert eval_in("jank.accept.interleave", "(doall (interleave [1 2 3] [:a]))") == [1, :a]

      load_slice("slice_61_lazy_cat.bl", "jank.accept.lazycat")
      assert eval_in("jank.accept.lazycat", "(doall (lazy-cat [1 2] [3]))") == [1, 2, 3]
    end

    test "for comprehends, nests, and stays lazy" do
      load_slice("slice_44_for.bl", "jank.accept.for")

      assert eval_in("jank.accept.for", "(doall (for [x [1 2 3]] (* x x)))") == [1, 4, 9]

      # Nested bindings iterate right-to-left, as Clojure's do.
      assert eval_in("jank.accept.for", "(doall (for [x [1 2] y [3 4]] [x y]))") ==
               [
                 BeamLisp.Vector.new([1, 3]),
                 BeamLisp.Vector.new([1, 4]),
                 BeamLisp.Vector.new([2, 3]),
                 BeamLisp.Vector.new([2, 4])
               ]

      assert eval_in("jank.accept.for", "(doall (for [x (range 10) :when (even? x)] x))") ==
               [0, 2, 4, 6, 8]

      # The point of `for` being lazy: an unbounded source is fine as
      # long as nobody asks for all of it.
      assert eval_in("jank.accept.for", "(doall (take 3 (for [x (range)] (* 2 x))))") == [0, 2, 4]
    end

    # --- promoted by wave 24 (widen-the-sample, third). The reduce /
    # transducer family's pure members, the tail-of-file seq fns, and
    # the numeric predicates. Transducer 1-arities that need volatile!/
    # reduced are measured in docs/jank-compat.md, NOT promoted here.

    test "completing adds the arity-1 and arity-0 signatures to a reducing fn" do
      load_slice("slice_71_completing.bl", "jank.accept.completing")
      assert eval_in("jank.accept.completing", "((completing +) 1 2)") == 3
      assert eval_in("jank.accept.completing", "((completing +) 7)") == 7
      assert eval_in("jank.accept.completing", "((completing +))") == 0
    end

    test "reduce folds with no init, and the [f init coll] arity now via the cpp shim" do
      # Upstream reduce's [f coll] arity is self-recursive and works; its
      # [f init coll] arity calls cpp/jank.runtime.reduce. Wave 25 widened
      # the cpp shim to cover it, so both arities now behave — and the cpp
      # reduce genuinely short-circuits on a Reduced, peeling the sentinel.
      load_slice("slice_70_reduce.bl", "jank.accept.reduce")
      assert eval_in("jank.accept.reduce", "(reduce + [1 2 3])") == 6
      assert eval_in("jank.accept.reduce", "(reduce (fn [a b] (if (> a b) a b)) [3 1 4 1 5])") == 5
      assert eval_in("jank.accept.reduce", "(reduce + 10 [1 2 3])") == 16
      assert eval_in(
               "jank.accept.reduce",
               "(reduce (fn [a b] (if (>= a 5) (reduced a) (+ a b))) 0 [1 2 3 4 5])"
             ) == 6
    end

    test "not= negates = at every arity" do
      load_slice("slice_79_not_eq.bl", "jank.accept.noteq")
      assert eval_in("jank.accept.noteq", "(not= 1 2)") == true
      assert eval_in("jank.accept.noteq", "(not= 1 1)") == false
      assert eval_in("jank.accept.noteq", "(not= 1 2 3)") == true
    end

    test "pos-int? tests a positive fixed-precision integer" do
      # Upstream pos-int? calls int?, which resolves to beam-lisp's
      # native int? (the cpp-based one is measured separately).
      load_slice("slice_84_signed_int_preds.bl", "jank.accept.posint")
      assert eval_in("jank.accept.posint", "(pos-int? 5)") == true
      assert eval_in("jank.accept.posint", "(pos-int? -5)") == false
      assert eval_in("jank.accept.posint", "(pos-int? 0)") == false
    end

    test "nthnext returns the nth seq or nil" do
      load_slice("slice_86_nthnext.bl", "jank.accept.nthnext")
      assert eval_in("jank.accept.nthnext", "(nthnext [1 2 3] 2)") == [3]
      # seq of a vector is the vector itself (beam-lisp's hybrid model)
      assert eval_in("jank.accept.nthnext", "(nthnext [1 2 3] 0)") ==
               BeamLisp.Vector.new([1, 2, 3])
      assert eval_in("jank.accept.nthnext", "(nthnext [1 2 3] 5)") == nil
    end

    test "nthrest returns the nth rest or empty" do
      load_slice("slice_87_nthrest.bl", "jank.accept.nthrest")
      assert eval_in("jank.accept.nthrest", "(nthrest [1 2 3] 2)") == [3]
      assert eval_in("jank.accept.nthrest", "(nthrest [1 2 3] 5)") == []
      assert eval_in("jank.accept.nthrest", "(nthrest [1 2 3] 0)") ==
               BeamLisp.Vector.new([1, 2, 3])
    end

    test "take-nth keeps every nth item (coll + transducer arity; rem now core)" do
      load_slice("slice_88_take_nth.bl", "jank.accept.takenth")
      assert eval_in("jank.accept.takenth", "(doall (take-nth 2 [1 2 3 4]))") == [1, 3]
      assert eval_in("jank.accept.takenth", "(doall (take-nth 3 (range 10)))") == [0, 3, 6, 9]

      # The stateful 1-arity transducer uses `(rem i n)`; its wave-25
      # blocker was `rem`, not `volatile!` — wave 26 shipped `rem`, so it
      # now reduces correctly.
      assert eval_in("jank.accept.takenth", "(transduce (take-nth 2) + 0 [1 2 3 4 5])") == 9
    end

    test "map applies f across one or more colls (vendored upstream arities)" do
      # The vendored map carries its own multi-coll arities, which recur
      # into itself — so two-collection map works here even though
      # core's map is single-coll (the gap drop-last/mapv hit).
      load_slice("slice_89_map.bl", "jank.accept.map")
      assert eval_in("jank.accept.map", "(doall (map inc [1 2 3]))") == [2, 3, 4]
      assert eval_in("jank.accept.map", "(doall (map + [1 2 3] [10 20 30]))") == [11, 22, 33]
    end

    test "map-indexed threads the index (coll arity; transducer needs volatile!)" do
      load_slice("slice_90_map_indexed.bl", "jank.accept.mapindexed")
      assert eval_in("jank.accept.mapindexed", "(doall (map-indexed + [10 20 30]))") ==
               [10, 21, 32]
    end

    test "keep drops nil results" do
      load_slice("slice_91_keep.bl", "jank.accept.keep")
      assert eval_in("jank.accept.keep", "(doall (keep #(when (odd? %) %) [1 2 3 4]))") == [1, 3]
    end

    test "keep-indexed drops nil results, threading the index" do
      load_slice("slice_92_keep_indexed.bl", "jank.accept.keepindexed")

      assert eval_in(
               "jank.accept.keepindexed",
               "(doall (keep-indexed (fn [i x] (when (odd? i) x)) [1 2 3 4]))"
             ) == [2, 4]
    end

    test "split-with partitions by a predicate (needs upstream juxt)" do
      # split-with is (juxt take-while drop-while), so it needs the
      # `juxt` slice co-loaded — core.jank's own dependency. Both halves
      # are lazy since wave 13, so pr-str realizes them for comparison.
      load_slice("slice_05_juxt.bl", "jank.accept.splitwith")
      load_slice("slice_94_split_with.bl", "jank.accept.splitwith")

      assert eval_in("jank.accept.splitwith", "(pr-str (split-with even? [2 4 5 6]))") ==
               "[(2 4) (5 6)]"

      assert eval_in("jank.accept.splitwith", "(pr-str (split-with pos? [1 -1 2]))") ==
               "[(1) (-1 2)]"
    end

    test "dorun forces a seq for side effects and returns nil" do
      load_slice("slice_96_dorun.bl", "jank.accept.dorun")
      assert eval_in("jank.accept.dorun", "(dorun [1 2 3])") == nil
      assert eval_in("jank.accept.dorun", "(dorun 2 [1 2 3])") == nil
    end

    test "doall forces a seq and returns it (needs upstream dorun)" do
      load_slice("slice_96_dorun.bl", "jank.accept.doall")
      load_slice("slice_97_doall.bl", "jank.accept.doall")
      assert eval_in("jank.accept.doall", "(doall [1 2 3])") == BeamLisp.Vector.new([1, 2, 3])
      assert eval_in("jank.accept.doall", "(doall 2 [1 2 3])") == BeamLisp.Vector.new([1, 2, 3])
    end

    test "take-last returns the last n items" do
      load_slice("slice_100_take_last.bl", "jank.accept.takelast")
      assert eval_in("jank.accept.takelast", "(doall (take-last 2 [1 2 3 4]))") == [3, 4]
    end

    test "mapv returns a vector (all arities, into + multi-coll map ship)" do
      # The 1-arity goes through transient/conj!/persistent!; the multi-coll
      # arities are `(into [] (map f c1 c2 …))`. Wave 26 shipped `into` and
      # core's multi-coll `map`, so all arities behave — mapv is ✓, not ◐.
      load_slice("slice_101_mapv.bl", "jank.accept.mapv")
      assert eval_in("jank.accept.mapv", "(mapv inc [1 2 3])") == BeamLisp.Vector.new([2, 3, 4])
      assert eval_in("jank.accept.mapv", "(mapv + [1 2 3] [10 20 30])") ==
               BeamLisp.Vector.new([11, 22, 33])
      assert eval_in("jank.accept.mapv", "(mapv + [1 2] [3 4] [5 6])") ==
               BeamLisp.Vector.new([9, 12])
    end

    test "filterv returns a vector of the kept items" do
      load_slice("slice_102_filterv.bl", "jank.accept.filterv")
      assert eval_in("jank.accept.filterv", "(filterv even? [1 2 3 4])") ==
               BeamLisp.Vector.new([2, 4])
      assert eval_in("jank.accept.filterv", "(filterv odd? [])") == BeamLisp.Vector.new([])
    end

    test "distinct? is true when no two args are equal" do
      load_slice("slice_103_distinct_q.bl", "jank.accept.distinctq")
      assert eval_in("jank.accept.distinctq", "(distinct? 1 2 3)") == true
      assert eval_in("jank.accept.distinctq", "(distinct? 1 2 1)") == false
      assert eval_in("jank.accept.distinctq", "(distinct? 1)") == true
      assert eval_in("jank.accept.distinctq", "(distinct? 1 1)") == false
    end

    test "filter keeps the items pred accepts (vendored coll arity)" do
      load_slice("slice_104_filter.bl", "jank.accept.filter")
      assert eval_in("jank.accept.filter", "(doall (filter even? [1 2 3 4 5]))") == [2, 4]
      assert eval_in("jank.accept.filter", "(doall (filter odd? (range 10)))") == [1, 3, 5, 7, 9]
    end

    test "dedupe removes consecutive duplicates (needs upstream when-some)" do
      # dedupe's coll arity walks with when-some, which is not a core
      # builtin — its own slice is co-loaded (core.jank's dependency).
      load_slice("slice_35_when_some.bl", "jank.accept.dedupe")
      load_slice("slice_105_dedupe.bl", "jank.accept.dedupe")
      assert eval_in("jank.accept.dedupe", "(doall (dedupe [1 1 2 3 3 1]))") == [1, 2, 3, 1]
      assert eval_in("jank.accept.dedupe", "(doall (dedupe []))") == []
    end

    test "nfirst is (next (first x))" do
      load_slice("slice_106_nfirst.bl", "jank.accept.nfirst")
      assert eval_in("jank.accept.nfirst", "(nfirst [[1 2] [3 4]])") == [2]
      assert eval_in("jank.accept.nfirst", "(nfirst [[1]])") == nil
    end

    test "fnext is (first (next x))" do
      load_slice("slice_107_fnext.bl", "jank.accept.fnext")
      assert eval_in("jank.accept.fnext", "(fnext [[1 2] [3 4]])") == BeamLisp.Vector.new([3, 4])
      assert eval_in("jank.accept.fnext", "(fnext [[1]])") == nil
    end

    test "map-entry? tests a 2-element vector" do
      load_slice("slice_109_map_entry_q.bl", "jank.accept.mapentryq")
      assert eval_in("jank.accept.mapentryq", "(map-entry? [:a 1])") == true
      assert eval_in("jank.accept.mapentryq", "(map-entry? [1 2 3])") == false
      assert eval_in("jank.accept.mapentryq", "(map-entry? {:a 1})") == false
    end

    test "not-every? is the negation of every?" do
      load_slice("slice_111_not_every_q.bl", "jank.accept.noteveryq")
      assert eval_in("jank.accept.noteveryq", "(not-every? even? [1 2 3])") == true
      assert eval_in("jank.accept.noteveryq", "(not-every? even? [2 4])") == false
    end

    test "replicate builds n copies (deprecated alias of take+repeat)" do
      load_slice("slice_112_replicate.bl", "jank.accept.replicate")
      assert eval_in("jank.accept.replicate", "(doall (replicate 3 :x))") == [:x, :x, :x]
    end

    test "comparator turns a binary pred into a -1/0/1 comparator" do
      load_slice("slice_113_comparator.bl", "jank.accept.comparator")
      assert eval_in("jank.accept.comparator", "((comparator <) 1 2)") == -1
      assert eval_in("jank.accept.comparator", "((comparator <) 2 1)") == 1
      assert eval_in("jank.accept.comparator", "((comparator <) 2 2)") == 0
    end

    # --- promoted by wave 25 (re-measure). The cpp/jank.runtime shim
    # widened (reduce/reduced/is_reduced/peek/pop/promoting_inc and the
    # is_* predicates), the reader learned `^{:arglists …}` / `^{:inline
    # …}` metadata, and volatile!/vreset!/vswap! shipped. Twenty previously-
    # failing slices now load AND behave. The four upstream TODO stubs
    # (with-open, instance?, rseq, unchecked-inc-int) still throw by
    # construction and are recorded, not counted against beam-lisp.

    test "list? via ^{:arglists …} metadata and the is_list shim" do
      # This is the head-of-core.jank dialect that used to fail at the
      # reader: a `(def ^{:arglists '([x]) :doc …} list? (fn* …))`.
      load_slice("slice_65_meta_def.bl", "jank.accept.listq")
      assert eval_in("jank.accept.listq", "(list? '(1 2))") == true
      assert eval_in("jank.accept.listq", "(list? [1 2])") == false
    end

    test "reduced wraps a value for early reduction termination" do
      load_slice("slice_66_reduced.bl", "jank.accept.reduced")
      assert eval_in("jank.accept.reduced", "(deref (reduced 42))") == 42
    end

    test "reduced? tests the reduced wrapper" do
      load_slice("slice_67_reduced_q.bl", "jank.accept.reducedq")
      assert eval_in("jank.accept.reducedq", "(reduced? (reduced 5))") == true
      assert eval_in("jank.accept.reducedq", "(reduced? 5)") == false
    end

    test "ensure-reduced returns its arg if reduced, else wraps it" do
      load_slice("slice_68_ensure_reduced.bl", "jank.accept.ensurereduced")

      assert eval_in("jank.accept.ensurereduced", "(reduced? (ensure-reduced (reduced 5)))") ==
               true

      assert eval_in("jank.accept.ensurereduced", "(reduced? (ensure-reduced 5))") == true
      assert eval_in("jank.accept.ensurereduced", "(deref (ensure-reduced 5))") == 5
    end

    test "unreduced unwraps a reduced, passes others through" do
      load_slice("slice_69_unreduced.bl", "jank.accept.unreduced")
      assert eval_in("jank.accept.unreduced", "(unreduced (reduced 5))") == 5
      assert eval_in("jank.accept.unreduced", "(unreduced 5)") == 5
    end

    test "transduce reduces with a transformed reducing fn" do
      # The canonical example needs the 1-arity `(map inc)` xform, which is
      # core.jank's own map (vendored slice 89) co-loaded.
      load_slice("slice_89_map.bl", "jank.accept.transduce")
      load_slice("slice_72_transduce.bl", "jank.accept.transduce")
      assert eval_in("jank.accept.transduce", "(transduce (map inc) + 0 [1 2 3])") == 9
      # the no-init arity reaches the same completing step (f ret)
      assert eval_in("jank.accept.transduce", "(transduce (map inc) + [1 2 3])") == 9
    end

    test "preserving-reduced re-wraps a reduced result" do
      load_slice("slice_73_preserving_reduced.bl", "jank.accept.preservingreduced")
      assert eval_in("jank.accept.preservingreduced", "((preserving-reduced +) 1 2)") == 3

      assert eval_in(
               "jank.accept.preservingreduced",
               "(reduced? ((preserving-reduced (fn [a b] (reduced 99))) 1 2))"
             ) == true
    end

    test "cat concatenates each input collection into the reduction" do
      # cat's body calls preserving-reduced (its core.jank dependency).
      load_slice("slice_73_preserving_reduced.bl", "jank.accept.cat")
      load_slice("slice_74_cat.bl", "jank.accept.cat")
      load_slice("slice_72_transduce.bl", "jank.accept.cat")
      assert eval_in("jank.accept.cat", "(transduce cat + 0 [[1 2] [3 4]])") == 10
    end

    test "peek reads a vector's last or a list's first, nil when empty" do
      load_slice("slice_75_peek.bl", "jank.accept.peek")
      assert eval_in("jank.accept.peek", "(peek [1 2 3])") == 3
      assert eval_in("jank.accept.peek", "(peek [])") == nil
      assert eval_in("jank.accept.peek", "(peek '(1 2 3))") == 1
    end

    test "pop removes a vector's last or a list's first" do
      load_slice("slice_76_pop.bl", "jank.accept.pop")
      assert eval_in("jank.accept.pop", "(pr-str (pop [1 2 3]))") == "[1 2]"
      assert eval_in("jank.accept.pop", "(pr-str (pop '(1 2 3)))") == "(2 3)"
    end

    test "volatile! with vreset! and vswap! builds a mutable cell" do
      # The definition carries ^{:inline (fn* …)} metadata — the reader
      # gate that used to fail this slice at load.
      load_slice("slice_77_volatile.bl", "jank.accept.volatile")
      assert eval_in("jank.accept.volatile", "(deref (volatile! 5))") == 5

      assert eval_in(
               "jank.accept.volatile",
               "(let [v (volatile! 0)] (vreset! v 7) (vswap! v + 3) @v)"
             ) == 10
    end

    test "inc' promotes past the fixed-precision boundary" do
      load_slice("slice_81_promoting_arith.bl", "jank.accept.promoting")
      assert eval_in("jank.accept.promoting", "(inc' 5)") == 6
    end

    test "int? tests a fixed-precision integer (is_integer shim)" do
      load_slice("slice_83_int_q.bl", "jank.accept.intq")
      assert eval_in("jank.accept.intq", "(int? 5)") == true
      assert eval_in("jank.accept.intq", "(int? 5.0)") == false
    end

    test "drop-last returns all but the last n (needs the vendored multi-coll map)" do
      # drop-last is (map (fn [x _] x) coll (drop n coll)) — a two-coll map.
      # It resolves `map` to core.jank's own multi-coll map (slice 89); the
      # docs note that beam-lisp's native map is still single-coll.
      load_slice("slice_89_map.bl", "jank.accept.droplast")
      load_slice("slice_93_drop_last.bl", "jank.accept.droplast")
      assert eval_in("jank.accept.droplast", "(doall (drop-last [1 2 3 4]))") == [1, 2, 3]
      assert eval_in("jank.accept.droplast", "(doall (drop-last 2 [1 2 3 4 5]))") == [1, 2, 3]
    end

    test "interpose separates elements with sep (needs upstream interleave)" do
      load_slice("slice_40_interleave.bl", "jank.accept.interpose")
      load_slice("slice_95_interpose.bl", "jank.accept.interpose")
      assert eval_in("jank.accept.interpose", "(doall (interpose :x [1 2 3]))") ==
               [1, :x, 2, :x, 3]

      # and its 1-arity is a stateful (volatile!-based) transducer
      load_slice("slice_72_transduce.bl", "jank.accept.interpose")
      assert eval_in("jank.accept.interpose", "(transduce (interpose 10) + 0 [1 2 3])") == 26
    end

    test "reductions yields the intermediate values of a reduction" do
      load_slice("slice_98_reductions.bl", "jank.accept.reductions")
      assert eval_in("jank.accept.reductions", "(doall (reductions + [1 2 3]))") == [1, 3, 6]

      assert eval_in("jank.accept.reductions", "(doall (reductions + 10 [1 2 3]))") ==
               [10, 11, 13, 16]
    end

    test "into pours a collection into another, with or without a transducer" do
      # Promoted in wave 27, after being REFUSED once: an earlier round claimed
      # it on a passing load, and calling it showed two arities still throwing.
      # Both root causes are now closed -- `conj!` grew a map-transient clause
      # and `map`/`filter` grew their 1-arity transducer forms -- so every
      # arity upstream defines is exercised here, not just the easy one.
      load_slice("slice_99_into.bl", "jank.accept.into")

      # The zero/one arities upstream declares.
      assert eval_in("jank.accept.into", "(into)") == BeamLisp.Vector.new([])
      assert eval_in("jank.accept.into", "(into [9])") == BeamLisp.Vector.new([9])

      # to + from, across every target kind: the transient fast path for
      # vector/map/set, and a list source for the reduce path.
      assert eval_in("jank.accept.into", "(into [] [1 2 3])") == BeamLisp.Vector.new([1, 2, 3])
      assert eval_in("jank.accept.into", "(into [] '(1 2))") == BeamLisp.Vector.new([1, 2])
      assert eval_in("jank.accept.into", "(into {} [[:a 1] [:b 2]])") == %{a: 1, b: 2}
      assert eval_in("jank.accept.into", "(into {} {:a 1})") == %{a: 1}

      # to + xform + from -- the arity that failed at xform CONSTRUCTION
      # before `map`/`filter` had their transducer forms.
      assert eval_in("jank.accept.into", "(into [] (map inc) [1 2 3])") ==
               BeamLisp.Vector.new([2, 3, 4])

      assert eval_in("jank.accept.into", "(into [] (filter odd?) [1 2 3])") ==
               BeamLisp.Vector.new([1, 3])
    end

    test "ratio?, decimal? and sorted? are always false on the BEAM" do
      # beam-lisp has no Ratio, BigDecimal, or sorted-collection type, so
      # each is genuinely false for every value — the honest answer.
      load_slice("slice_114_ratio.bl", "jank.accept.ratio")
      assert eval_in("jank.accept.ratio", "(ratio? 3)") == false
      load_slice("slice_115_decimal_rational.bl", "jank.accept.decimal")
      assert eval_in("jank.accept.decimal", "(decimal? 3)") == false
      load_slice("slice_116_sorted_preds.bl", "jank.accept.sorted")
      assert eval_in("jank.accept.sorted", "(sorted? {})") == false
    end

    test "NaN? is always false because beam-lisp cannot produce a NaN" do
      # The slice behaves: no reachable value is NaN. beam-lisp has no
      # `##NaN` literal, `(/ 0.0 0.0)` raises, and there is no Math module,
      # so the true branch is unreachable — recorded, not a defect.
      load_slice("slice_120_nan_q.bl", "jank.accept.nanq")
      assert eval_in("jank.accept.nanq", "(NaN? 3.0)") == false
      assert eval_in("jank.accept.nanq", "(NaN? 3)") == false
    end

    test "transducer 1-arities reduce correctly with a completing rf" do
      # volatile!/reduced? now ship, so the previously-"needs volatile!"
      # transducer 1-arities behave. transduce's final `(f ret)` requires
      # rf to accept a 1-arity (the completing convention); driving them
      # with `+` avoids `conj`'s missing 1-arity (a recorded core gap).
      load_slice("slice_72_transduce.bl", "jank.accept.tx37")
      load_slice("slice_37_take_while.bl", "jank.accept.tx37")
      load_slice("slice_72_transduce.bl", "jank.accept.tx38")
      load_slice("slice_38_drop_while.bl", "jank.accept.tx38")
      load_slice("slice_72_transduce.bl", "jank.accept.tx49")
      load_slice("slice_49_distinct.bl", "jank.accept.tx49")
      load_slice("slice_72_transduce.bl", "jank.accept.tx90")
      load_slice("slice_90_map_indexed.bl", "jank.accept.tx90")
      load_slice("slice_72_transduce.bl", "jank.accept.tx92")
      load_slice("slice_92_keep_indexed.bl", "jank.accept.tx92")
      load_slice("slice_72_transduce.bl", "jank.accept.tx105")
      load_slice("slice_35_when_some.bl", "jank.accept.tx105")
      load_slice("slice_105_dedupe.bl", "jank.accept.tx105")

      assert eval_in("jank.accept.tx37", "(transduce (take-while odd?) + 0 [1 3 4])") == 4
      assert eval_in("jank.accept.tx38", "(transduce (drop-while odd?) + 0 [1 3 5 2 4])") == 6
      assert eval_in("jank.accept.tx49", "(transduce (distinct) + 0 [1 1 2 3 3 1])") == 6

      assert eval_in(
               "jank.accept.tx90",
               "(transduce (map-indexed (fn [i x] (* i x))) + 0 [1 2 3 4])"
             ) == 20

      assert eval_in(
               "jank.accept.tx92",
               "(transduce (keep-indexed (fn [i x] x)) + 0 [1 2 3 4])"
             ) == 10

      assert eval_in("jank.accept.tx105", "(transduce (dedupe) + 0 [1 1 2 3 3 1])") == 7
    end

    # --- promoted by wave 26 (the core-gaps backlog). `rem`, `float?`,
    # `bit_not`, `transientable?`, `reduce-kv`, and `take`'s transducer
    # 1-arity were the wave-25 failure list's exact small-prim gaps; they
    # shipped, and with them eight of the nine then-failing slices. The
    # exceptions and their root causes are recorded in docs/jank-compat.md
    # (`into` stays un-promoted: its map-target and `map`-xform paths still
    # throw). Each slice is called with its own docstring semantics.

    test "bit-not is the two's-complement complement" do
      load_slice("slice_78_bit_ops.bl", "jank.accept.bitnot")
      assert eval_in("jank.accept.bitnot", "(bit-not 5)") == -6
      assert eval_in("jank.accept.bitnot", "(bit-not -1)") == 0
      assert eval_in("jank.accept.bitnot", "(bit-not 0)") == -1
    end

    test "mod truncates toward negative infinity, matching rem's sign" do
      load_slice("slice_80_mod.bl", "jank.accept.mod")
      assert eval_in("jank.accept.mod", "(mod 13 4)") == 1
      assert eval_in("jank.accept.mod", "(mod -13 4)") == 3
      assert eval_in("jank.accept.mod", "(mod 13 -4)") == -3
    end

    test "double? tests a floating-point value via float?" do
      load_slice("slice_85_double_q.bl", "jank.accept.doubleq")
      assert eval_in("jank.accept.doubleq", "(double? 3.0)") == true
      assert eval_in("jank.accept.doubleq", "(double? 0.5)") == true
      assert eval_in("jank.accept.doubleq", "(double? 3)") == false
    end

    test "splitv-at returns a vector of an into-take vector and the drop" do
      load_slice("slice_117_splitv_at.bl", "jank.accept.splitvat")

      assert eval_in("jank.accept.splitvat", "(splitv-at 2 [1 2 3 4 5])") ==
               BeamLisp.Vector.new([BeamLisp.Vector.new([1, 2]), [3, 4, 5]])

      assert eval_in("jank.accept.splitvat", "(splitv-at 3 (list 1 2 3 4 5 6))") ==
               BeamLisp.Vector.new([BeamLisp.Vector.new([1, 2, 3]), [4, 5, 6]])
    end

    test "update-vals maps f over the values, preserving keys and meta" do
      load_slice("slice_118_update_vals.bl", "jank.accept.updatevals")
      assert eval_in("jank.accept.updatevals", "(update-vals {:a 1 :b 2} inc)") == %{a: 2, b: 3}

      assert eval_in("jank.accept.updatevals", "(update-vals {:a 1 :b 2} (fn [v] (* v 10)))") ==
               %{a: 10, b: 20}
    end

    test "update-keys maps f over the keys, preserving values" do
      load_slice("slice_119_update_keys.bl", "jank.accept.updatekeys")

      assert eval_in("jank.accept.updatekeys", "(update-keys {1 \"a\" 2 \"b\"} inc)") ==
               %{2 => "a", 3 => "b"}

      assert eval_in("jank.accept.updatekeys", "(update-keys {:a 1 :b 2} name)") ==
               %{"a" => 1, "b" => 2}
    end

  end
end
