defmodule BeamLisp.Wave26CoreGapsTest do
  # wave 26: the small-prim backlog that was ranked last wave and never
  # built — transientable?, reduce-kv, rem, float?, bit-not, multi-coll
  # map. Each is verified by *running* the vendored jank slice it unblocks
  # (the same verbatim fixtures jank_compat_test checksum-guards), so a pass
  # means upstream core.jank code executes, not that a beam-lisp
  # reimplementation agrees with itself. mod (80), bit-not (78), double?
  # (85) and take-nth (88) are slice-local defs; into (99), mapv (101),
  # splitv-at (117), update-vals (118) and update-keys (119) resolve the
  # prims — transientable?, reduce-kv, rem, float?, multi-coll map — from
  # core. The sha256 guard below locks the "no local edits" claim for the
  # seven slices that were recorded FAILs in docs/jank-compat.md.
  use ExUnit.Case, async: false

  @moduletag :wave26

  # {fixture-basename, slice-ns}. Each loads its own copy of its fn into a
  # throwaway ns, mirroring the jank_compat harness.
  @slices [
    {"slice_78_bit_ops", "w26.s78",
     "a3526cc4e40a6c1e6dbc20a7c930f703f58f11077dd4a9e332d407ea23c95b63"},
    {"slice_80_mod", "w26.s80",
     "a294d54fcce083c581eb597500ef49299fbef7f70f86b2dd94ba97840f3ce890"},
    {"slice_85_double_q", "w26.s85",
     "b6351689e09567917469b8711b06f3faf5f3bada7a113fa12bc25b03729661d7"},
    {"slice_88_take_nth", "w26.s88",
     "12bd2618c253513c0dbb1912e66a60f33963265ed21f2c2b4f30cb915c081ec0"},
    {"slice_99_into", "w26.s99",
     "137470a3955d15d86263db032b01f47bf55d7997062ff93f562705d62f028bb6"},
    {"slice_101_mapv", "w26.s101",
     "1df3d96917e8d546bb67e9788981942e216f8c22ed206a32127b79bf93742c43"},
    {"slice_117_splitv_at", "w26.s117",
     "7c0414717303e587b15b81ec2277bf99aa8ec4526900f90867b448a0dc74e117"},
    {"slice_118_update_vals", "w26.s118",
     "231c6303bbda1e3d4c5733c183405c2865007fa7222cb83760df5c88c52c39a2"},
    {"slice_119_update_keys", "w26.s119",
     "9cdffcd4664abbfc73d27002538ee30ccb82f9bb46434bed4abfa6dfcf5ee496"}
  ]

  setup do
    BeamLisp.init()
    :ok
  end

  defp fixture_code(name) do
    Path.join(["test", "fixtures", "jank", name <> ".bl"])
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, ";"))
    |> Enum.join("\n")
  end

  # Load a slice into its own ns so its fn resolves from that ns + core.
  defp load_slice(name, ns) do
    BeamLisp.Compiler.eval_string("(ns #{ns})\n" <> fixture_code(name), BeamLisp.Compiler.new_env(ns))
  end

  defp eval_in(ns, source), do: BeamLisp.Compiler.eval_string(source, BeamLisp.Compiler.new_env(ns))

  test "the seven recorded-FAIL slices are byte-for-byte upstream (no local edits)" do
    for {name, _ns, expected} <- @slices do
      actual = :crypto.hash(:sha256, fixture_code(name)) |> Base.encode16(case: :lower)
      assert actual == expected, "#{name} drifts from upstream core.jank — fidelity claim void"
    end
  end

  describe "slice-local defs (mod, bit-not, double?, take-nth)" do
    test "bit-not complements a two's-complement integer (slice 78)" do
      load_slice("slice_78_bit_ops", "w26.s78")
      assert eval_in("w26.s78", "(bit-not 5)") == -6
      assert eval_in("w26.s78", "(bit-not -6)") == 5
      assert eval_in("w26.s78", "(bit-not 0)") == -1
    end

    test "mod differs from rem on negative operands (slice 80)" do
      load_slice("slice_80_mod", "w26.s80")
      # rem keeps the dividend's sign: rem(-7, 3) is -1 …
      assert eval_in("w26.s80", "(rem -7 3)") == -1
      assert eval_in("w26.s80", "(rem 7 -3)") == 1
      # … mod keeps the divisor's sign: mod(-7, 3) is 2, not -1
      assert eval_in("w26.s80", "(mod 7 3)") == 1
      assert eval_in("w26.s80", "(mod -7 3)") == 2
      assert eval_in("w26.s80", "(mod 7 -3)") == -2
      assert eval_in("w26.s80", "(mod -7 -3)") == -1
      assert eval_in("w26.s80", "(mod 0 3)") == 0
      # the two agree on same-sign operands — the silent-wrong-answer trap
      assert eval_in("w26.s80", "(= (mod -7 -3) (rem -7 -3))") == true
      assert eval_in("w26.s80", "(not= (mod -7 3) (rem -7 3))") == true
    end

    test "double? derives from float? (slice 85)" do
      load_slice("slice_85_double_q", "w26.s85")
      assert eval_in("w26.s85", "(double? 1.5)") == true
      assert eval_in("w26.s85", "(float? 2.5)") == true
      assert eval_in("w26.s85", "(double? 1)") == false
      assert eval_in("w26.s85", "(double? \"a\")") == false
    end

    test "take-nth transducer 1-arity drives a transduce (slice 88)" do
      load_slice("slice_88_take_nth", "w26.s88")
      # the coll arity
      assert eval_in("w26.s88", "(doall (take-nth 2 [1 2 3 4]))") == [1, 3]
      assert eval_in("w26.s88", "(doall (take-nth 3 (range 10)))") == [0, 3, 6, 9]
      # the transducer 1-arity — blocked by `rem` before wave 26
      assert eval_in("w26.s88", "(transduce (take-nth 2) conj [] [1 2 3 4 5 6])") ==
               BeamLisp.Vector.new([1, 3, 5])
    end
  end

  describe "core-prim slices (into, mapv, splitv-at, update-vals, update-keys)" do
    test "into respects transientable? and takes an xform (slice 99)" do
      load_slice("slice_99_into", "w26.s99")
      assert eval_in("w26.s99", "(into [] [1 2 3])") == BeamLisp.Vector.new([1, 2, 3])
      assert eval_in("w26.s99", "(into [0] [1 2 3])") == BeamLisp.Vector.new([0, 1, 2, 3])
      # a list target is not transientable, so it conj's (prepends)
      assert eval_in("w26.s99", "(into '(9) [1 2 3])") == [3, 2, 1, 9]
      # 3-arity: xform through transduce + the transient conj! path
      assert eval_in("w26.s99", "(into [] (take 2) [1 2 3 4])") == BeamLisp.Vector.new([1, 2])
    end

    test "mapv maps across multiple colls via core's multi-coll map (slice 101)" do
      load_slice("slice_101_mapv", "w26.s101")
      # 1-coll: the transient-reduce path
      assert eval_in("w26.s101", "(mapv inc [1 2 3])") == BeamLisp.Vector.new([2, 3, 4])
      # 2/3-coll: (into [] (map f …)) over core's multi-coll map
      assert eval_in("w26.s101", "(mapv + [1 2 3] [10 20 30])") == BeamLisp.Vector.new([11, 22, 33])
      assert eval_in("w26.s101", "(mapv + [1 2 3] [10 20 30] [100 200 300])") ==
               BeamLisp.Vector.new([111, 222, 333])
    end

    test "splitv-at uses (into [] (take n) coll) (slice 117)" do
      load_slice("slice_117_splitv_at", "w26.s117")
      assert eval_in("w26.s117", "(splitv-at 2 [1 2 3 4])") ==
               BeamLisp.Vector.new([BeamLisp.Vector.new([1, 2]), [3, 4]])
      # take past the end yields an empty first half, the full rest as the second
      assert eval_in("w26.s117", "(splitv-at 0 [1 2])") ==
               BeamLisp.Vector.new([BeamLisp.Vector.new([]), [1, 2]])
    end

    test "update-vals folds with reduce-kv over a transient map (slice 118)" do
      load_slice("slice_118_update_vals", "w26.s118")
      assert eval_in("w26.s118", "(update-vals {:a 1 :b 2} inc)") == %{a: 2, b: 3}
      assert eval_in("w26.s118", "(update-vals {} inc)") == %{}
    end

    test "update-keys folds keys with reduce-kv (slice 119)" do
      load_slice("slice_119_update_keys", "w26.s119")
      assert eval_in("w26.s119", "(update-keys {:a 1} name)") == %{"a" => 1}
      assert eval_in("w26.s119", "(update-keys {} str)") == %{}
    end
  end

  describe "the core prims themselves, cross-checked against slices" do
    test "transientable? answers honestly for every beam-lisp collection type" do
      load_slice("slice_99_into", "w26.s99")
      # vectors, maps, sets get a transient view; lists, lazy seqs, scalars don't
      assert eval_in("w26.s99", "(transientable? [])") == true
      assert eval_in("w26.s99", "(transientable? {})") == true
      # \#{ is escaped: in Elixir `#{` would interpolate, in beam-lisp it is a set literal
      assert eval_in("w26.s99", "(transientable? \#{})") == true
      assert eval_in("w26.s99", "(transientable? '(1 2))") == false
      assert eval_in("w26.s99", "(transientable? (range 3))") == false
      assert eval_in("w26.s99", "(transientable? nil)") == false
      assert eval_in("w26.s99", "(transientable? 5)") == false
    end

    test "reduce-kv runs over maps and vectors (indices as keys)" do
      load_slice("slice_118_update_vals", "w26.s118")
      assert eval_in("w26.s118", "(reduce-kv (fn [acc k v] (+ acc (* k v))) 0 {2 10 3 20})") == 80
      # vector keys are indices: 0*10 + 1*20 + 2*30 = 80
      assert eval_in("w26.s118", "(reduce-kv (fn [acc i x] (+ acc (* i x))) 0 [10 20 30])") == 80
    end

    test "multi-coll map stops at the shortest input" do
      load_slice("slice_101_mapv", "w26.s101")
      assert eval_in("w26.s101", "(doall (map + [1 2 3] [10 20]))") == [11, 22]
      assert eval_in("w26.s101", "(doall (map + [1 2] [10 20 30]))") == [11, 22]
      # one exhausted coll ends the map; the rest are ignored
      assert eval_in("w26.s101", "(doall (map + [1 2 3] []))") == []
    end
  end
end
