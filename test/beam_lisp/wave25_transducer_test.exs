defmodule BeamLisp.Wave25TransducerTest do
  # The transducer layer is exercised through *vendored jank slices* —
  # the same verbatim fixtures jank_compat_test checksum-guards — so a
  # pass here means upstream core.jank code actually runs, not that a
  # beam-lisp reimplementation agrees. Loading several slices into one
  # namespace mirrors the doc's co-loading rule (core.jank's own
  # dependency chains).
  use ExUnit.Case, async: false

  @ns "jank.w25"

  @slices ~w(
    04_comp 37_take_while 38_drop_while 48_mapcat 49_distinct 66_reduced
    67_reduced_q 68_ensure_reduced 69_unreduced 70_reduce 71_completing
    72_transduce 73_preserving_reduced 74_cat 75_peek 76_pop 81_promoting_arith
    83_int_q 88_take_nth 89_map 90_map_indexed 92_keep_indexed 95_interpose
    98_reductions 105_dedupe 114_ratio 115_decimal_rational 116_sorted_preds 120_nan_q
  )

  setup do
    BeamLisp.init()

    # Re-seed the cpp shim prims and core defs each run, then load every
    # slice into one namespace so cross-slice calls (transduce → reduce,
    # mapcat → cat → preserving-reduced) resolve exactly as they would in
    # core.jank.
    src =
      @slices
      |> Enum.map(&fixture_code/1)
      |> Enum.join("\n")

    BeamLisp.Compiler.eval_string("(ns #{@ns})\n" <> src, BeamLisp.Compiler.new_env(@ns))
    BeamLisp.Env.in_ns("user")
    :ok
  end

  defp fixture_code(name) do
    Path.join(["test", "fixtures", "jank", "slice_#{name}.bl"])
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, ";"))
    |> Enum.join("\n")
  end

  defp in_slice(source), do: BeamLisp.Compiler.eval_string(source, BeamLisp.Compiler.new_env(@ns))
  defp user(source), do: BeamLisp.eval(source)

  describe "reduced short-circuits reduce" do
    test "a Reduced step result halts the fold and yields its unwrapped value" do
      # The step fn stops the moment it sees a value > 3. 1+2+3=6 is the
      # running total at that point; 4 and 5 are never folded.
      assert in_slice("(reduce (fn [a x] (if (> x 3) (reduced a) (+ a x))) 0 [1 2 3 4 5])") == 6
    end

    test "reduced?/ensure-reduced/unreduced round-trip through the wrapper" do
      assert in_slice("(reduced? (reduced 42))") == true
      assert in_slice("(reduced? 42)") == false
      assert in_slice("(reduced? (ensure-reduced (reduced 5)))") == true
      assert in_slice("(unreduced (reduced 7))") == 7
      # unreduced passes a plain value through untouched.
      assert in_slice("(unreduced 9)") == 9
    end

    test "reduce returns init for an empty coll and folds a vector" do
      assert in_slice("(reduce + 10 [])") == 10
      assert in_slice("(reduce + 0 [1 2 3 4])") == 10
    end

    test "core reduce (not just the vendored one) respects reduced" do
      user("(def w25-core-r (reduce (fn [a x] (if (> x 3) (reduced a) (+ a x))) 0 [1 2 3 4 5]))")
      assert user("w25-core-r") == 6
    end
  end

  describe "transduce" do
    test "map transducer over cpp reduce" do
      assert in_slice("(transduce (map inc) + 0 [1 2 3])") == 9
    end

    test "take-while transducer stops via reduced" do
      assert in_slice("(transduce (take-while #(< % 4)) + 0 [1 2 3 4 5 6])") == 6
    end

    test "completing supplies the arity-1 step so conj can be a reducing fn" do
      assert in_slice("(transduce (map inc) (completing conj) [] [1 2 3])") == %BeamLisp.Vector{
               items: {2, 3, 4}
             }
    end
  end

  describe "cat and the transducer 1-arities (previously untested)" do
    test "cat concatenates each input collection into the reduction" do
      assert in_slice("(transduce cat (completing conj) [] [[1 2] [3] [4 5]])") ==
               %BeamLisp.Vector{items: {1, 2, 3, 4, 5}}
    end

    test "mapcat's transducer composes map and cat" do
      assert in_slice("(transduce (mapcat (fn [x] [x (* x x)])) (completing conj) [] [1 2 3])") ==
               %BeamLisp.Vector{items: {1, 1, 2, 4, 3, 9}}
    end

    test "distinct transducer keeps first occurrences" do
      assert in_slice("(transduce (distinct) (completing conj) [] [1 2 1 3 2 1])") ==
               %BeamLisp.Vector{items: {1, 2, 3}}
    end

    test "drop-while transducer skips leading matches then emits the rest" do
      assert in_slice("(transduce (drop-while #(< % 3)) (completing conj) [] [1 2 3 4 1 2])") ==
               %BeamLisp.Vector{items: {3, 4, 1, 2}}
    end

    test "take-while transducer keeps leading matches then stops" do
      assert in_slice("(transduce (take-while #(< % 4)) (completing conj) [] [1 2 3 4 5])") ==
               %BeamLisp.Vector{items: {1, 2, 3}}
    end

    test "map-indexed transducer pairs each element with its index" do
      assert in_slice(
               "(transduce (map-indexed (fn [i x] [i x])) (completing conj) [] [:a :b :c])"
             ) == %BeamLisp.Vector{
               items: {BeamLisp.Vector.new([0, :a]), BeamLisp.Vector.new([1, :b]), BeamLisp.Vector.new([2, :c])}
             }
    end

    test "keep-indexed transducer drops nil results" do
      assert in_slice(
               "(transduce (keep-indexed (fn [i x] (when (even? i) x))) (completing conj) [] [0 1 2 3 4])"
             ) == %BeamLisp.Vector{items: {0, 2, 4}}
    end

    test "dedupe transducer removes consecutive duplicates" do
      assert in_slice("(transduce (dedupe) (completing conj) [] [1 1 2 2 3 1])") ==
               %BeamLisp.Vector{items: {1, 2, 3, 1}}
    end

    test "interpose transducer inserts sep between elements" do
      assert in_slice("(transduce (interpose :x) (completing conj) [] [1 2 3])") ==
               %BeamLisp.Vector{items: {1, :x, 2, :x, 3}}
    end

    test "take-nth collection arity still passes" do
      # take-nth's transducer 1-arity also needs `rem`, which is a
      # separate core gap (docs/jank-compat.md gap 7) — not this wave's.
      assert in_slice("(doall (take-nth 2 [0 1 2 3 4 5 6]))") == [0, 2, 4, 6]
    end
  end

  describe "cpp/* shim entries through their vendored slice paths" do
    test "peek: last of a vector, first of a seq, nil when empty" do
      assert in_slice("(peek [1 2 3])") == 3
      assert in_slice("(peek '(1 2 3))") == 1
      assert in_slice("(peek [])") == nil
    end

    test "pop: vector without last, seq without first, empty throws" do
      assert in_slice("(pop [1 2 3])") == %BeamLisp.Vector{items: {1, 2}}
      assert in_slice("(pop '(1 2 3))") == [2, 3]
      assert_raise ArgumentError, fn -> in_slice("(pop [])") end
    end

    test "promoting_inc is plain + on arbitrary-precision integers" do
      assert in_slice("(inc' 41)") == 42
      assert in_slice("(inc' 4611686018427387904)") == 4611686018427387905
    end

    test "int? (is_integer)" do
      assert in_slice("(int? 3)") == true
      assert in_slice("(int? 3.0)") == false
    end

    test "is_* predicates honestly report beam-lisp's type space" do
      # No Ratio, no BigDecimal, no sorted collection, no NaN reachable
      # here — each is genuinely false for every value.
      assert in_slice("(ratio? 3)") == false
      assert in_slice("(decimal? 3.0)") == false
      assert in_slice("(sorted? [1 2])") == false
      assert in_slice("(NaN? 1.0)") == false
    end
  end

  describe "volatiles" do
    test "volatile! / deref read the initial value" do
      user("(def w25-v (volatile! 10))")
      assert user("@w25-v") == 10
      assert user("(deref w25-v)") == 10
    end

    test "vreset! overwrites and returns the new value" do
      user("(def w25-v (volatile! 1))")
      assert user("(vreset! w25-v 99)") == 99
      assert user("@w25-v") == 99
      # nil is a legal volatile value (drop-while's transducer stores it).
      assert user("(vreset! w25-v nil)") == nil
      assert user("@w25-v") == nil
    end

    test "vswap! reads-modifies-writes and returns the new value" do
      user("(def w25-v (volatile! -1))")
      assert user("(vswap! w25-v inc)") == 0
      assert user("(vswap! w25-v inc)") == 1
      assert user("@w25-v") == 1
    end

    test "vswap! with extra step args" do
      user("(def w25-v (volatile! 0))")
      assert user("(vswap! w25-v + 5)") == 5
      assert user("@w25-v") == 5
    end

    test "volatile? distinguishes volatiles from atoms" do
      user("(def w25-v (volatile! 0))")
      user("(def w25-a (atom 0))")
      assert user("(volatile? w25-v)") == true
      assert user("(volatile? w25-a)") == false
      assert user("(volatile? 42)") == false
    end

    test "a volatile is process-local: invisible across a process boundary" do
      # The honest contract: visible only in the creating process. Hand
      # the box to another process and deref there returns nil (the value
      # never left home), which is exactly why volatiles must not be used
      # for cross-process coordination — atoms are for that.
      user("(def w25-v (volatile! 7))")
      assert user("@w25-v") == 7
      result =
        BeamLisp.Refs.deref(
          user("(future (deref w25-v))")
        )

      assert result == nil
    end
  end

  describe "interleave/interpose are lazy in their inputs" do
    test "interpose over an infinite seq with take terminates" do
      assert in_slice("(take 5 (interpose :x (range)))") == [0, :x, 1, :x, 2]
    end

    test "interleave with an infinite first coll and take terminates" do
      assert in_slice("(take 5 (interleave (repeat :sep) (range)))") == [:sep, 0, :sep, 1, :sep]
    end

    test "interpose finite result equals the expected seq and prints" do
      assert in_slice("(= (interpose :x [1 2 3]) '(1 :x 2 :x 3))") == true
      assert BeamLisp.RT.print_str(in_slice("(interpose :x [1 2 3])")) == "(1 :x 2 :x 3)"
    end

    test "doall of a lazy interleave realizes to a proper list" do
      assert in_slice("(doall (interleave (repeat :sep) [1 2]))") == [:sep, 1, :sep, 2]
    end
  end
end
