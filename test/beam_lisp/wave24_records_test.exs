defmodule BeamLisp.Wave24RecordsTest do
  # Wave 24: deftype and defrecord. Records are real Elixir structs (a map
  # with a known key set plus a type) so Elixir interop, IO.inspect and
  # pattern matching work on them; the type name is interned as a var whose
  # value is the struct module. Because a struct satisfies `is_map`, the
  # RT's map clauses are routed through record-aware clauses that exclude
  # the internal `__struct__` key — these tests exist to prove a record is
  # never silently swallowed by a plain-map clause.
  use ExUnit.Case, async: false

  alias BeamLisp.Compiler
  alias BeamLisp.{Env, RT, Test}

  setup do
    BeamLisp.init()
    Env.in_ns("user")
    # `keys`/`vals`/`merge`/`into` used to be defined here, because none of
    # them shipped in the prelude yet. Wave 27 added all four, so the local
    # copies are gone: they were being `defn`d into the shared `user`
    # namespace, which OUTLIVES the test file, and whichever ran last won.
    # That made `(keys nil)` return `()` instead of nil in roughly two runs
    # in three -- a real cross-test leak, not a flake. The record assertions
    # below now exercise the shipped implementations, which is what they were
    # always trying to prove.
    :ok
  end

  defp eval(source), do: Compiler.eval_string(source, Compiler.new_env("user"))

  describe "constructors" do
    test "->Point builds a record with the declared fields" do
      eval("(defrecord W24Point [x y])")
      assert eval("(->W24Point 1 2)") == %{__struct__: BeamLisp.Record.User.W24Point, x: 1, y: 2}
    end

    test "map->Point builds a record from a map's known fields, dropping extras" do
      eval("(defrecord W24Point [x y])")
      assert eval("(map->W24Point {:x 1 :y 2 :z 3})") ==
               %{__struct__: BeamLisp.Record.User.W24Point, x: 1, y: 2}
    end

    test "a field not in the map defaults to nil" do
      eval("(defrecord W24Point [x y])")
      assert eval("(map->W24Point {:x 1})") ==
               %{__struct__: BeamLisp.Record.User.W24Point, x: 1, y: nil}
    end

    test "the constructor enforces arity" do
      eval("(defrecord W24Point [x y])")
      assert_raise ArgumentError, fn -> eval("(->W24Point 1)") end
      assert_raise ArgumentError, fn -> eval("(->W24Point 1 2 3)") end
    end
  end

  describe "record is a map" do
    setup do
      eval("(defrecord W24Point [x y])")
      :ok
    end

    test "keyword lookup and get both work" do
      assert eval("(:x (->W24Point 1 2))") == 1
      assert eval("(:y (->W24Point 1 2))") == 2
      assert eval("(get (->W24Point 1 2) :x)") == 1
      assert eval("(get (->W24Point 1 2) :z :missing)") == :missing
    end

    test "assoc on a known key preserves the record type" do
      assert eval("(assoc (->W24Point 1 2) :x 9)") ==
               %{__struct__: BeamLisp.Record.User.W24Point, x: 9, y: 2}
    end

    test "assoc on an unknown key adds it and stays a record" do
      assert eval("(assoc (->W24Point 1 2) :z 3)") ==
               %{__struct__: BeamLisp.Record.User.W24Point, x: 1, y: 2, z: 3}
    end

    test "count/keys/vals/seq read the public fields, never __struct__" do
      assert eval("(count (->W24Point 1 2))") == 2
      assert eval("(count (assoc (->W24Point 1 2) :z 3))") == 3
      assert Test.realize(eval("(keys (->W24Point 1 2))")) == [:x, :y]
      assert Test.realize(eval("(vals (->W24Point 1 2))")) == [1, 2]
      assert Test.realize(eval("(map first (seq (->W24Point 1 2)))")) == [:x, :y]
      assert eval("(contains? (->W24Point 1 2) :x)") == true
      assert eval("(find (->W24Point 1 2) :y)") == %BeamLisp.Vector{items: {:y, 2}}
    end

    test "the internal __struct__ key is not part of the record surface" do
      assert eval("(get (->W24Point 1 2) :__struct__)") == nil
      assert eval("(contains? (->W24Point 1 2) :__struct__)") == false
      assert eval("(find (->W24Point 1 2) :__struct__)") == nil
      assert_raise ArgumentError, fn -> eval("(assoc (->W24Point 1 2) :__struct__ 9)") end
    end

    test "map?/coll? report a record the way Clojure does" do
      # Clojure's `(map? record)` is true, and so is ours: a record IS a
      # user-facing map here -- count/seq/get/assoc/find/coll? all already
      # treat it as one, so map? answering false made it the lone dissenter.
      # (This assertion previously claimed the opposite while its name claimed
      # Clojure fidelity; the wave-27 dispatch table caught the contradiction.)
      assert eval("(map? (->W24Point 1 2))") == true
      assert eval("(coll? (->W24Point 1 2))") == true

      # But only RECORDS. A non-record struct is not a map.
      assert eval("(map? (map inc [1 2]))") == false
      assert eval("(map? [1 2])") == false
      assert eval("(map? (atom 1))") == false
    end
  end

  describe "equality" do
    test "records of the same type and value are equal" do
      eval("(defrecord W24Point [x y])")
      assert eval("(= (->W24Point 1 2) (->W24Point 1 2))") == true
      assert eval("(= (->W24Point 1 2) (->W24Point 1 3))") == false
    end

    test "records of different types with identical fields are not equal" do
      eval("(defrecord W24Point [x y])")
      eval("(defrecord W24Coord [x y])")
      assert eval("(= (->W24Point 1 2) (->W24Coord 1 2))") == false
    end

    test "a record and a plain map with the same entries are not equal" do
      eval("(defrecord W24Point [x y])")
      assert eval("(= (->W24Point 1 2) {:x 1 :y 2})") == false
    end

    test "the map value equality is preserved (nested values compare by value)" do
      eval("(defrecord W24Point [x y])")
      eval("(defrecord W24Vec [v])")
      assert eval("(= (->W24Vec [1 2]) (->W24Vec [1 2]))") == true
    end
  end

  describe "inline protocol implementations" do
    test "defrecord inline protocol methods dispatch on the record" do
      eval("""
      (defprotocol W24Shape (w24-area [this]) (w24-perim [this]))
      (defrecord W24Rect [w h]
        W24Shape
        (w24-area [this] (* (:w this) (:h this)))
        (w24-perim [this] (+ (* 2 (:w this)) (* 2 (:h this)))))
      """)

      assert eval("(w24-area (->W24Rect 3 4))") == 12
      assert eval("(w24-perim (->W24Rect 3 4))") == 14
    end

    test "inline impl and a separate extend-type are interchangeable" do
      eval("""
      (defprotocol W24Shape2 (w24-area2 [this]))
      (defrecord W24Rect [w h] W24Shape2 (w24-area2 [this] (* (:w this) (:h this))))
      """)

      assert eval("(w24-area2 (->W24Rect 2 5))") == 10
      # extend-type on the same record type keys the same tag.
      eval("(extend-type W24Rect W24Shape2 (w24-area2 [this] (+ (:w this) (:h this))))")
      assert eval("(w24-area2 (->W24Rect 2 5))") == 7
    end

    test "a record of a non-implementing type has no method (raises)" do
      eval("""
      (defprotocol W24Shape3 (w24-area3 [this]))
      (defrecord W24Rect [w h] W24Shape3 (w24-area3 [this] 42))
      (defrecord W24Point [x y])
      """)

      assert eval("(w24-area3 (->W24Rect 1 2))") == 42
      assert_raise RuntimeError, fn -> eval("(w24-area3 (->W24Point 1 2))") end
    end

    test "a protocol extended via extend-type dispatches on a record" do
      eval("(defrecord W24Pt [x y])")
      eval("(defprotocol W24Norm (w24-norm [this]))")
      eval("(extend-type W24Pt W24Norm (w24-norm [this] (+ (:x this) (:y this))))")
      assert eval("(w24-norm (->W24Pt 3 4))") == 7
    end
  end

  describe "deftype" do
    test "deftype has the ->Name constructor and named-field access, but no map semantics" do
      eval("(deftype W24Line [a b])")
      assert eval("(.-a (->W24Line 1 2))") == 1
      assert eval("(.b (->W24Line 1 2))") == 2

      # No map semantics: not a map, no keyword access.
      assert eval("(map? (->W24Line 1 2))") == false
      assert_raise FunctionClauseError, fn -> eval("(:a (->W24Line 1 2))") end
      assert_raise FunctionClauseError, fn -> eval("(get (->W24Line 1 2) :a)") end
      assert_raise FunctionClauseError, fn -> eval("(count (->W24Line 1 2))") end
    end

    test "deftype implements a protocol inline" do
      eval("""
      (defprotocol W24Len (w24-len [this]))
      (deftype W24Vec [x y] W24Len (w24-len [this] (+ (.-x this) (.-y this))))
      """)

      assert eval("(w24-len (->W24Vec 3 4))") == 7
    end

    test "deftype instances are distinct by type" do
      eval("(deftype W24A [n])")
      eval("(deftype W24B [n])")
      assert eval("(= (->W24A 1) (->W24A 1))") == true
      assert eval("(= (->W24A 1) (->W24B 1))") == false
    end
  end

  describe "pr-str round-trip" do
    test "a record prints readably and reads back to an equal record" do
      eval("(defrecord W24Point [x y])")

      printed = eval("(pr-str (->W24Point 1 2))")
      assert printed == "#user/W24Point{:x 1, :y 2}"

      read_back = Compiler.eval_string(printed, Compiler.new_env("user"))
      original = eval("(->W24Point 1 2)")
      assert RT.eqv(read_back, original)
      assert RT.eqv(read_back, eval("(->W24Point 1 3)")) == false
    end

    test "a record literal in source constructs the record" do
      eval("(defrecord W24Point [x y])")
      assert eval("(= #user/W24Point{:x 1 :y 2} (->W24Point 1 2))") == true
    end
  end

  describe "no is_map clause swallows a record" do
    setup do
      eval("(defrecord W24Point [x y])")
      :ok
    end

    test "map/filter over a record iterate its entries, not struct fields" do
      assert Test.realize(eval("(map first (seq (->W24Point 1 2)))")) == [:x, :y]
      assert eval("(count (map identity (seq (->W24Point 1 2))))") == 2
      assert Test.realize(eval("(filter (fn [e] (> (second e) 1)) (seq (->W24Point 1 2)))")) ==
               [%BeamLisp.Vector{items: {:y, 2}}]
    end

    test "reduce over a record folds its entries" do
      assert eval("(reduce (fn [acc e] (+ acc (second e))) 0 (seq (->W24Point 1 2)))") == 3
    end

    test "into collects the record's entries into a vector" do
      assert eval("(into [] (seq (->W24Point 1 2)))") ==
               %BeamLisp.Vector{
                 items: {%BeamLisp.Vector{items: {:x, 1}}, %BeamLisp.Vector{items: {:y, 2}}}
               }

      assert eval("(count (into [] (seq (->W24Point 1 2))))") == 2
    end

    test "merge reads the record's entries into a map" do
      # merge starts from {} so the result is a plain map; the point is that
      # seq/assoc over the record never leak __struct__.
      assert eval("(merge (->W24Point 1 2) {:z 3})") == %{x: 1, y: 2, z: 3}
      assert Test.realize(eval("(keys (merge (->W24Point 1 2) {:z 3}))")) == [:x, :y, :z]
    end

    test "str and print-str print the record (not its struct fields)" do
      assert eval("(str (->W24Point 1 2))") == "#user/W24Point{:x 1, :y 2}"
      assert eval("(print-str (->W24Point 1 2))") == "#user/W24Point{:x 1, :y 2}"
      refute String.contains?(eval("(str (->W24Point 1 2))"), "__struct__")
    end

    test "conj with a [k v] entry assocs onto a record" do
      assert eval("(conj (->W24Point 1 2) [:z 3])") ==
               %{__struct__: BeamLisp.Record.User.W24Point, x: 1, y: 2, z: 3}
    end
  end
end
