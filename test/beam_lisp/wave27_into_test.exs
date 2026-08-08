defmodule BeamLisp.Wave27IntoTest do
  @moduledoc """
  `into` was the last genuine failure in the 120-slice jank sample, and it
  failed for two unrelated reasons that both had to close before it could be
  promoted:

    1. `BeamLisp.Transient.conj!/2` had clauses for vector and set transients
       only, so `into`'s fast path exploded the moment the target was a map.
    2. Core `map`/`filter` had no 1-arity transducer form, so
       `(into [] (map inc) coll)` died at xform *construction* -- before
       `into`'s body ran at all.

  Two workers hit these independently this wave, from different directions
  (one porting Specter's `determine-params-impls`, one measuring jank). Two
  independent reports of the same friction is the strongest signal available
  that something is a root cause rather than an edge case.

  These tests drive the compiler, so the file is `async: false`: concurrent
  `Module.create` on a shared namespace module fails outright.
  """
  use ExUnit.Case, async: false

  alias BeamLisp.Vector

  setup do
    BeamLisp.init()
    BeamLisp.Env.in_ns("user")
    :ok
  end

  defp eval(code) do
    case BeamLisp.Compiler.eval_string(code, BeamLisp.Compiler.new_env("user")) do
      {v, _env} -> v
      v -> v
    end
  end

  describe "into, across every target kind" do
    test "a vector target keeps vector-ness and order" do
      assert eval("(into [] [1 2 3])") == Vector.new([1, 2, 3])
      assert eval("(into [0] [1 2])") == Vector.new([0, 1, 2])
      # A list source reduces through the same path; `[] != ()` is a
      # deliberate distinction in this language, so the RESULT must be the
      # vector the target asked for, whatever the source was.
      assert eval("(into [] '(1 2))") == Vector.new([1, 2])
    end

    test "a map target accepts both entry shapes" do
      # `seq` over a map yields 2-element vectors, and a literal `[k v]`
      # source reduces to the same shape -- this is what `conj!` now accepts.
      assert eval("(into {} [[:a 1] [:b 2]])") == %{a: 1, b: 2}
      # A quoted 2-element LIST is the other legal entry spelling.
      assert eval("(into {} '((:a 1)))") == %{a: 1}
      # Map into map, entries taken via seq.
      assert eval("(into {} {:a 1})") == %{a: 1}
      # A later duplicate key wins, as assoc would.
      assert eval("(into {} [[:a 1] [:a 9]])") == %{a: 9}
    end

    test "a set target dedupes" do
      assert eval("(into (set []) [1 2 2])") |> BeamLisp.Set.to_list() |> Enum.sort() ==
               [1, 2]
    end

    test "an entry of the wrong shape fails loudly rather than mis-binding" do
      # Silently taking the first two elements of a 3-vector would corrupt the
      # map with a plausible-looking result -- the worst kind of failure.
      assert_raise ArgumentError, fn -> eval("(into {} [[:a 1 :extra]])") end
    end

    test "the empty and identity arities upstream declares" do
      assert eval("(into)") == Vector.new([])
      assert eval("(into [9])") == Vector.new([9])
      assert eval("(into [] [])") == Vector.new([])
      assert eval("(into {} [])") == %{}
    end

    test "nil punning follows Clojure" do
      assert eval("(into [] nil)") == Vector.new([])
    end

    test "a reference type is not a source -- the wave-1 hole stays shut" do
      # Reference types are not collections. If `into` ever starts reading one,
      # it is reading %Atom{}'s internal struct fields.
      assert_raise ArgumentError, fn -> eval("(into [] (atom 1))") end
    end
  end

  describe "transducer arities" do
    test "(map f) with no collection returns a transducer" do
      assert eval("(into [] (map inc) [1 2 3])") == Vector.new([2, 3, 4])
      assert eval("(into [] (map inc) [])") == Vector.new([])
    end

    test "(filter pred) with no collection returns a transducer" do
      assert eval("(into [] (filter odd?) [1 2 3])") == Vector.new([1, 3])
      assert eval("(into [] (filter odd?) [2 4])") == Vector.new([])
    end

    test "a transducer works into a map target too" do
      assert eval("(into {} (map identity) [[:a 1]])") == %{a: 1}
    end

    test "the collection arities are untouched by the transducer forms" do
      # `map`/`filter` were REBOUND to add their 1-arity forms. The collection
      # arities must still delegate to the original chunked-lazy primitives --
      # a second, Lisp-level lazy implementation would be a parallel impl of
      # something that already exists, and would drift.
      assert eval("(doall (map inc [1 2]))") == [2, 3]
      assert eval("(doall (filter odd? [1 2 3]))") == [1, 3]
      # multi-collection map is part of that same primitive
      assert eval("(doall (map + [1 2] [10 20]))") == [11, 22]
    end

    test "laziness survives the rebinding" do
      # This is the PLAN-010 guarantee and the thing most at risk from
      # redefining `map`: if the rebound map were eager, this would realize a
      # million cells. Counting, not timing -- timing proves speed, only a
      # count proves laziness.
      eval("(def realized (atom 0))")

      eval("""
      (def head
        (doall (take 3 (map (fn [x] (do (swap! realized inc) (inc x)))
                            (range 1 1000000)))))
      """)

      assert eval("head") == [2, 3, 4]
      # Chunked at 32: one chunk, not a million.
      assert eval("@realized") == 32
    end
  end

  describe "merge" do
    test "later keys win and nils are skipped" do
      assert eval("(merge {:a 1} {:b 2})") == %{a: 1, b: 2}
      assert eval("(merge {:a 1} {:a 9})") == %{a: 9}
      assert eval("(merge nil {:a 1})") == %{a: 1}
      assert eval("(merge {:a 1} nil)") == %{a: 1}
      assert eval("(merge {:a 1} {:b 2} {:c 3})") == %{a: 1, b: 2, c: 3}
    end

    test "merging nothing is nil, so (apply merge '()) works" do
      # Clojure returns nil rather than {} for the empty case, which is what
      # makes `(apply merge maps)` safe on an empty seq.
      assert eval("(merge)") == nil
      assert eval("(apply merge [])") == nil
    end

    test "a record merges as the map it is, yielding a plain map" do
      eval("(defrecord W27M [x y])")
      # The result carries a key the record's type never declared, so it
      # cannot remain that type.
      assert eval("(merge (->W27M 1 2) {:z 3})") == %{x: 1, y: 2, z: 3}
    end
  end
end
