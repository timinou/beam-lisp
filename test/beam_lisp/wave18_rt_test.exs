defmodule BeamLisp.Wave18RTTest do
  # Wave 18: sets, `seq`-on-map iteration, sort/compare, the cpp/*
  # interop shim, and the select-keys/flatten dependencies (conj
  # map-entry, sequential?/tree-seq/complement).
  #
  # The is_map audit runs implicitly throughout: every collection fn
  # that guards on `is_map` must match the set struct FIRST (count,
  # first, seq, next, contains?, coll?, printing), or a set would be
  # read as its struct fields.
  use ExUnit.Case, async: false

  @moduletag :wave18

  defp eval_in(source), do: eval_in("wave18", source)

  defp eval_in(ns, source) do
    BeamLisp.init()
    BeamLisp.Compiler.eval_string(source, BeamLisp.Compiler.new_env(ns))
  end

  defp load_fixture(fixture, ns) do
    code =
      ["test", "fixtures", "jank", fixture]
      |> Path.join()
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, ";"))
      |> Enum.join("\n")

    BeamLisp.init()
    BeamLisp.Compiler.eval_string("(ns #{ns})\n" <> code, BeamLisp.Compiler.new_env(ns))
  end

  describe "sets" do
    test "set constructs distinct members" do
      assert eval_in("(set [1 2 2 3 3 3])") == eval_in("(set [1 2 3])")
      assert eval_in("(set '(a b a))") == eval_in("(set '(a b))")
      assert eval_in("(set [])") == eval_in("(set nil)")
    end

    test "set? and map?-is-false" do
      assert eval_in("(set? (set [1 2]))") == true
      assert eval_in("(set? [1 2])") == false
      assert eval_in("(set? {:a 1})") == false
      assert eval_in("(set? nil)") == false
      assert eval_in("(map? (set [1 2]))") == false
    end

    test "membership via contains?" do
      assert eval_in("(contains? (set [1 2 3]) 2)") == true
      assert eval_in("(contains? (set [1 2 3]) 9)") == false
    end

    test "conj adds (idempotent), disj removes (idempotent)" do
      assert eval_in("(= (conj (set [1 2]) 3) (set [1 2 3]))") == true
      assert eval_in("(= (conj (set [1 2]) 2) (set [1 2]))") == true
      assert eval_in("(= (disj (set [1 2 3]) 2) (set [1 3]))") == true
      assert eval_in("(= (disj (set [1 2]) 9) (set [1 2]))") == true
    end

    test "count, first, seq, coll? read members, not struct fields" do
      assert eval_in("(count (set [1 2 2 3]))") == 3
      assert eval_in("(count (set []))") == 0
      assert eval_in("(coll? (set [1 2]))") == true
      assert eval_in("(seq (set []))") == nil
      assert eval_in("(seq (set [5 1]))") != nil
      # every member of (seq (set [5 1])) is a member of the set
      assert eval_in("(every? #(contains? (set [5 1]) %) (seq (set [5 1])))") == true
      assert eval_in("(set? (first (map identity [(set [1])])))") == true
    end

    test "equality: set-set structural, set distinct from vector/list/map" do
      assert eval_in("(= (set [1 2 3]) (set [3 2 1]))") == true
      assert eval_in("(= (set [1 2]) (set [1 2 3]))") == false
      assert eval_in("(= (set [1 2]) [1 2])") == false
      assert eval_in("(= (set [1 2]) '(1 2))") == false
      assert eval_in("(= (set [1 2]) {:a 1})") == false
      assert eval_in("(not= (set [1]) (set [2]))") == true
    end

    test "printing is a set literal" do
      result = eval_in("(pr-str (set [1 2 3]))")
      assert result == "\#{1 2 3}" or result == "\#{3 2 1}"
    end

    test "map/filter iterate set members" do
      assert eval_in("(set (map inc (set [1 2 3])))") == eval_in("(set [2 3 4])")
    end

    # The struct-is-a-map audit: every collection fn that guards on
    # `is_map` must see a set's members, never its struct fields.
    test "is_map audit: a set flows through every is_map-guarded fn correctly" do
      assert eval_in("(count (set [1 2 3]))") == 3
      assert eval_in("(first (set [5 1]))") in [1, 5]
      assert eval_in("(seq (set []))") == nil
      assert eval_in("(next (set [1]))") == nil
      assert eval_in("(contains? (set [1 2]) 2)") == true
      assert eval_in("(coll? (set [1 2]))") == true
      assert eval_in("(map? (set [1 2]))") == false
      assert eval_in("(get (set [:a :b]) :a)") == :a
      assert eval_in("(get (set [:a :b]) :zz)") == nil
      assert eval_in("(vector? (set [1]))") == false
      assert eval_in("(list? (set [1]))") == false
      # rest of a set is its remaining members (a list), empty when done
      assert eval_in("(= (rest (set [1 2])) (seq (disj (set [1 2]) (first (set [1 2])))))") == true
      assert_raise ArgumentError, fn -> eval_in("(assoc (set [1 2]) :k :v)") end
    end
  end

  describe "seq on a map (merge-with)" do
    test "seq yields [k v] entries, driving reduce/key/val" do
      assert eval_in("(key (find {:a 1} :a))") == :a
      assert eval_in("(val (find {:a 1} :a))") == 1
      assert eval_in("(= (set (map key (seq {:a 1 :b 2}))) (set [:a :b]))") == true
    end

    test "slice 58 merge-with loads verbatim and behaves" do
      load_fixture("slice_58_merge_with.bl", "wave18.mw")
      ns = "wave18.mw"
      assert eval_in(ns, "(merge-with + {:a 1 :b 2} {:a 3 :c 4})") == %{a: 4, b: 2, c: 4}
      assert eval_in(ns, "(merge-with (fn [x y] (* x y)) {:a 2} {:a 3 :b 4})") == %{a: 6, b: 4}
      assert eval_in(ns, "(merge-with + {:a 1} nil)") == %{a: 1}
    end
  end

  describe "sort and compare" do
    test "compare orders numbers, strings, keywords, symbols, nil" do
      assert eval_in("(compare 1 2)") == -1
      assert eval_in("(compare 2 1)") == 1
      assert eval_in("(compare 3 3)") == 0
      assert eval_in("(compare nil 1)") == -1
      assert eval_in("(compare 1 nil)") == 1
      assert eval_in("(compare false true)") == -1
      assert eval_in("(compare \"a\" \"b\")") == -1
      assert eval_in("(compare :a :b)") == -1
      assert eval_in("(compare 'a 'b)") == -1
    end

    test "compare orders collections element-wise" do
      assert eval_in("(compare [1 2] [1 3])") == -1
      assert eval_in("(compare [1 2] [1 2])") == 0
      assert eval_in("(compare [1] [1 2])") == -1
      assert eval_in("(compare [1 2] [2])") == -1
    end

    test "mixed-type total order" do
      assert eval_in("(sort [10 :a nil \"x\" 5 false true])") ==
               eval_in("'(nil false true 5 10 \"x\" :a)")
    end

    test "sort asc and with a comparator" do
      assert eval_in("(= (sort [3 1 2]) '(1 2 3))") == true
      assert eval_in("(= (sort (fn [a b] (- b a)) [3 1 2]) '(3 2 1))") == true
      assert eval_in("(= (count (sort [])) 0)") == true
    end

    test "slice 59 sort-by loads verbatim and behaves" do
      load_fixture("slice_59_sort_by.bl", "wave18.sb")
      ns = "wave18.sb"
      assert eval_in(ns, "(sort-by first [[3 1] [1 2] [2 3]])") ==
               eval_in("'([1 2] [2 3] [3 1])")
    end
  end

  describe "cpp/* interop shim (slices 31/32/33)" do
    test "slice 31 name" do
      load_fixture("slice_31_name.bl", "wave18.nm")
      ns = "wave18.nm"
      assert eval_in(ns, "(name :foo)") == "foo"
      assert eval_in(ns, "(name 'foo)") == "foo"
      assert eval_in(ns, "(name \"foo\")") == "foo"
    end

    test "slice 32 namespace" do
      load_fixture("slice_32_namespace.bl", "wave18.nsp")
      ns = "wave18.nsp"
      assert eval_in(ns, "(namespace :a/b)") == "a"
      assert eval_in(ns, "(namespace 'a/b)") == "a"
      assert eval_in(ns, "(namespace :plain)") == nil
    end

    test "slice 33 keyword" do
      load_fixture("slice_33_keyword.bl", "wave18.kw")
      ns = "wave18.kw"
      assert eval_in(ns, "(keyword \"a\" \"b\")") == :"a/b"
      assert eval_in(ns, "(keyword \"foo\")") == :foo
      assert eval_in(ns, "(keyword 'foo)") == :foo
      assert eval_in(ns, "(keyword :already)") == :already
    end
  end

  describe "flatten deps (slice 50)" do
    test "sequential? distinguishes sequential from map/set/string" do
      assert eval_in("(sequential? [1 2])") == true
      assert eval_in("(sequential? '(1 2))") == true
      assert eval_in("(sequential? {:a 1})") == false
      assert eval_in("(sequential? (set [1]))") == false
      assert eval_in("(sequential? \"abc\")") == false
    end

    test "tree-seq walks nested vectors" do
      assert eval_in("(tree-seq sequential? seq [1 [2 [3 4]] 5])") ==
               eval_in("'([1 [2 [3 4]] 5] 1 [2 [3 4]] 2 [3 4] 3 4 5)")
    end

    test "slice 50 flatten loads verbatim and behaves" do
      load_fixture("slice_50_flatten.bl", "wave18.fl")
      ns = "wave18.fl"
      assert BeamLisp.Test.realize(eval_in(ns, "(flatten [1 [2 [3 4]] 5])")) == eval_in("'(1 2 3 4 5)")
      # flatten is lazy: flattening nil is an empty lazy seq, realized here
      assert BeamLisp.Test.realize(eval_in(ns, "(flatten nil)")) == []
    end
  end

  describe "select-keys (slice 28, conj map-entry)" do
    test "conj with a [k v] entry adds to a map" do
      assert eval_in("(conj {} (find {:a 1} :a))") == %{a: 1}
      assert eval_in("(conj {:b 2} (find {:a 1} :a))") == %{a: 1, b: 2}
    end

    test "slice 28 select-keys loads verbatim and behaves" do
      load_fixture("slice_28_select_keys.bl", "wave18.sk")
      ns = "wave18.sk"
      assert eval_in(ns, "(select-keys {:a 1 :b 2 :c 3} [:a :c])") == %{a: 1, c: 3}
      assert eval_in(ns, "(select-keys {:a 1 :b 2} [:a :zz])") == %{a: 1}
    end
  end

  describe "slice 30 set" do
    test "the vendored set runs on the reader's set literal and a transient set" do
      # The slice body is
      # `(persistent! (reduce … (transient #\{}) coll))`, so it needs
      # three things that now exist: the reader's set literal, a set
      # type, and a transient whose kind is a set.
      load_fixture("slice_30_set.bl", "wave18.set")

      assert BeamLisp.Compiler.eval_string(
               "(count (set [1 2 2 3]))",
               BeamLisp.Compiler.new_env("wave18.set")
             ) == 3

      assert BeamLisp.Compiler.eval_string(
               "(contains? (set [1 2]) 2)",
               BeamLisp.Compiler.new_env("wave18.set")
             ) == true
    end
  end
end
