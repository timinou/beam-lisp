defmodule BeamLisp.Wave28EngineTest do
  # The navigation algebra: NONE, composition, traversal.
  #
  # These tests are about PROPERTIES rather than cases, because the
  # engine's correctness is not a list of examples — it is a handful of
  # invariants that every navigator and every path must preserve. The
  # cases exist to demonstrate the invariants, not the other way round.
  #
  # async: false — driving the compiler concurrently against a shared
  # namespace fails outright.
  use ExUnit.Case, async: false

  setup do
    BeamLisp.init()
    :ok
  end

  # Each test compiles its own throwaway namespace requiring the engine.
  # One eval per test, because an alias belongs to the (ns …) form that
  # introduced it and does not survive into a later evaluation.
  defp eng(body) do
    BeamLisp.Compiler.eval_string(
      "(ns w28e.#{:erlang.unique_integer([:positive])} " <>
        "(:require [specter.engine :refer :all]))\n" <> body,
      BeamLisp.Compiler.new_env("user")
    )
  end

  defp v(list), do: BeamLisp.Vector.new(list)

  describe "NONE — the sentinel" do
    test "is identity-stable however it is reached" do
      # On the BEAM an atom is globally interned, so identity holds by
      # construction rather than by a cache's good behaviour. This is the
      # one place the BEAM is STRONGER than the JVM, and the engine's
      # whole control flow rests on it.
      assert eng("(none? NONE)") == true
      assert eng("(identical? NONE NONE)") == true
      # reached through a collection, a function return, and a rebinding
      assert eng("(none? (first [NONE]))") == true
      assert eng("(none? ((fn [] NONE)))") == true
      assert eng("(let [x NONE] (none? x))") == true
    end

    test "survives a message send, which copies every other term" do
      # The BEAM copies terms between processes. An atom is the exception:
      # it is the same interned word on both sides. If that were not true,
      # a navigator running in another process could not report NONE.
      assert eng("""
             (let [me (erlang/self)]
               (erlang/spawn (fn [] (erlang/send me NONE)))
               (receive x (none? x)))
             """) == true
    end

    test "is not confusable with a lookalike keyword" do
      assert eng("(none? :other)") == false
      assert eng("(none? :NONE)") == false
      assert eng("(none? :specter.engine/none)") == false
      assert eng("(none? nil)") == false
      assert eng("(none? false)") == false
    end

    test "a structure may legitimately contain a keyword and stay data" do
      # The hazard a sentinel always carries: user data that looks like
      # control flow. A keyword-valued map must survive selection
      # unharmed.
      assert eng("(none? (get {:k :NONE} :k))") == false
    end
  end

  describe "the navigator protocol" do
    test "STAY* navigates to the structure itself" do
      assert eng("(rich-nav? STAY*)") == true
      assert eng("(select* STAY* [] 42 (fn [vals s] s))") == 42
    end

    test "rich-nav? distinguishes navigators from data" do
      # rich-nav? asks whether a value ALREADY implements the protocol,
      # not whether it could be coerced into one — so 42 stays false even
      # once specter/navs.bl has taught the coercer to accept it.
      assert eng("[(rich-nav? STAY*) (rich-nav? 42) (rich-nav? :a) (rich-nav? [1])]") ==
               v([true, false, false, false])
    end

    test "coerce-object refuses a value nothing can coerce" do
      # "Not a navigator" alone is the least useful message a path error
      # could carry; the offending value and its type must be in it.
      #
      # The value has to be one NO ImplicitNav extension claims, and that
      # set shrinks as navigators load: specter/navs.bl extends integers,
      # keywords, strings and functions, and those registrations are
      # global and outlive the file that made them. An earlier version of
      # this test used 42 and passed only when it ran before navs.bl had
      # ever loaded — a seed-dependent failure, which on this project
      # means a leak rather than a flake. A boolean is coerced by nothing
      # and is not plausibly a future shorthand.
      err =
        assert_raise BeamLisp.ExInfo, fn ->
          eng("(coerce-object true)")
        end

      assert Exception.message(err) =~ "Not a navigator"
    end
  end

  describe "composition" do
    test "an empty path is the identity navigator" do
      # Navigating nowhere is still navigating: (select [] x) must yield
      # x, not an error.
      assert eng("(identical? (comp-paths* []) STAY*)") == true
    end

    test "a single-element path is that element, uncomposed" do
      # No wrapper: composition of one thing is the thing. Checked
      # observably, since the navigator is a reify with no name.
      assert eng("""
             (let [n (comp-paths* [STAY*])]
               [(rich-nav? n) (identical? n STAY*)])
             """) == v([true, true])
    end

    test "an already-compiled navigator passes through unchanged" do
      assert eng("(identical? (comp-paths* STAY*) STAY*)") == true
    end

    test "composition nests continuations, left to right" do
      # The heart of the engine. Two navigators that each record their
      # name prove the ORDER: the leftmost is outermost.
      assert eng("""
             (let [trace (volatile! [])
                   mk (fn [nm] (reify RichNavigator
                                 (select* [this vals s nf]
                                   (vswap! trace conj nm)
                                   (nf vals s))
                                 (transform* [this vals s nf] (nf vals s))))
                   p (comp-paths* [(mk :outer) (mk :inner)])]
               (select* p [] :x (fn [vals s] s))
               @trace)
             """) == v([:outer, :inner])
    end

    test "composes to arbitrary depth" do
      # Five levels, each incrementing, so the answer proves every layer
      # ran exactly once and in order.
      assert eng("""
             (let [bump (reify RichNavigator
                          (select* [this vals s nf] (nf vals (inc s)))
                          (transform* [this vals s nf] (nf vals (inc s))))
                   p (comp-paths* [bump bump bump bump bump])]
               (select* p [] 0 (fn [vals s] s)))
             """) == 5
    end

    test "a nested path vector composes as its elements" do
      # [[a b] c] and [a b c] must be the same navigator, because a
      # sub-path is a path.
      assert eng("""
             (let [bump (reify RichNavigator
                          (select* [this vals s nf] (nf vals (inc s)))
                          (transform* [this vals s nf] (nf vals (inc s))))
                   flat (comp-paths* [bump bump bump])
                   nested (comp-paths* [[bump bump] bump])]
               [(select* flat [] 0 (fn [v s] s))
                (select* nested [] 0 (fn [v s] s))])
             """) == v([3, 3])
    end
  end

  describe "traversal" do
    test "the terminal fn receives the bare structure when nothing collected" do
      assert eng("(compiled-traverse* STAY* (fn [x] x) 42)") == 42
    end

    test "and collected values alongside it when something was" do
      # A navigator that pushes onto vals makes the terminal fn receive a
      # vector of [collected… structure] — the mechanism behind putval.
      assert eng("""
             (let [collect (reify RichNavigator
                             (select* [this vals s nf] (nf (conj vals :c) s))
                             (transform* [this vals s nf] (nf (conj vals :c) s)))]
               (compiled-traverse* collect (fn [x] x) 42))
             """) == v([:c, 42])
    end

    test "an empty vals is distinguished from having collected nothing" do
      # Upstream checks this explicitly, and it matters: a navigator may
      # collect on one branch and not another, so "vals is empty" cannot
      # be conflated with "this traversal collects".
      assert eng("(compiled-traverse-with-vals* STAY* (fn [x] x) [] 42)") == 42
      assert eng("(compiled-traverse-with-vals* STAY* (fn [x] x) [:a] 42)") == v([:a, 42])
    end
  end
end
