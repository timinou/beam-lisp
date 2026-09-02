defmodule BeamLisp.Wave28PrimsTest do
  # The prims Specter's engine needs, plus the one bug found while
  # building them: `name` did not drop the namespace, so `(name :a/b)`
  # answered "a/b" where Clojure answers "b". Every caller that had been
  # using `name` to build a string was quietly getting a qualified one.
  #
  # `keyword`, `namespace` and `name` are deliberately tested TOGETHER,
  # because their contract is a roundtrip rather than three independent
  # behaviours: (keyword (namespace k) (name k)) must be k.
  use ExUnit.Case, async: false

  setup do
    BeamLisp.init()
    {:ok, e: BeamLisp.Compiler.new_env("w28prims")}
  end

  defp ev(src, e), do: BeamLisp.Compiler.eval_string(src, e)
  defp v(list), do: BeamLisp.Vector.new(list)

  describe "name" do
    test "drops the namespace, as Clojure does", %{e: e} do
      assert ev("(name :a)", e) == "a"
      assert ev("(name :a/b)", e) == "b"
      assert ev("(name 'x/y)", e) == "y"
      assert ev("(name 'plain)", e) == "plain"
    end

    test "passes a string through", %{e: e} do
      assert ev(~s{(name "s")}, e) == "s"
      assert ev(~s{(name "a/b")}, e) == "b"
    end

    test "the / var is a name, not a qualification", %{e: e} do
      # `/` is division's name. Splitting on the first slash would make
      # it an empty name in an empty namespace, which is why the split
      # rule requires a non-empty left half rather than merely a slash.
      assert ev("(name '/)", e) == "/"
      assert ev("(namespace '/)", e) == nil
    end
  end

  describe "namespace" do
    test "returns the qualifier or nil", %{e: e} do
      assert ev("(namespace :a/b)", e) == "a"
      assert ev("(namespace :a)", e) == nil
      assert ev("(namespace 'x/y)", e) == "x"
      assert ev("(namespace 'x)", e) == nil
    end

    test "nil rather than empty string is the contract", %{e: e} do
      # Callers branch on it; "" is truthy and would silently take the
      # qualified path.
      assert ev("(if (namespace :a) :qualified :bare)", e) == :bare
    end
  end

  describe "keyword" do
    test "builds from a name and from a namespace plus a name", %{e: e} do
      assert ev(~s{(keyword "a")}, e) == :a
      assert ev(~s{(keyword "ns" "n")}, e) == :"ns/n"
    end

    test "is equal to the literal it names", %{e: e} do
      assert ev(~s{(= (keyword "a") :a)}, e) == true
      assert ev(~s{(= (keyword "a" "b") :a/b)}, e) == true
    end

    test "is idempotent on a keyword", %{e: e} do
      assert ev(~s{(keyword (keyword "a"))}, e) == :a
      assert ev("(keyword :a/b)", e) == :"a/b"
    end

    test "accepts a symbol", %{e: e} do
      assert ev("(keyword 'foo)", e) == :foo
      # a qualified symbol keeps its qualification through the roundtrip
      assert ev("(keyword 'x/y)", e) == :"x/y"
    end

    test "roundtrips with name and namespace", %{e: e} do
      # The contract that makes the three functions one feature.
      assert ev("(let [k :a/b] (= k (keyword (namespace k) (name k))))", e) == true
    end

    test "goes through the atom guard, not String.to_atom" do
      # A keyword built at RUNTIME comes from data, and data can be
      # unbounded where source text is not: a loop interning one atom per
      # input row is exactly how the atom table fills, and a full table
      # aborts the VM uncatchably rather than raising.
      #
      # Asserted by construction rather than by exhausting the table:
      # the prim must route through BeamLisp.AtomGuard, so a source scan
      # is the honest check that no bare intern crept back in.
      src = File.read!("priv/boot/core.bl")
      [_, keyword_def | _] = String.split(src, "(defn keyword")
      body = String.slice(keyword_def, 0, 400)

      refute body =~ "binary_to_atom",
             "keyword/1,2 must not intern directly — route through the atom guard"

      assert body =~ "cpp/jank.runtime.keyword"
    end
  end

  describe "satisfies?" do
    setup %{e: e} do
      ev(
        """
        (ns w28prims)
        (defprotocol Shape (area [x]) (perim [x]))
        (extend-type :integer Shape (area [x] (* x x)) (perim [x] (* 4 x)))
        """,
        e
      )

      {:ok, e: e}
    end

    test "is true exactly when the call dispatches", %{e: e} do
      # The whole point of the predicate: it must not disagree with the
      # call it guards. Wave 27 retired `map?`-on-records for exactly
      # this failure mode.
      assert ev("(satisfies? Shape 3)", e) == true
      assert ev("(area 3)", e) == 9

      assert ev(~s{(satisfies? Shape "s")}, e) == false

      assert_raise RuntimeError, ~r/No implementation of method/, fn ->
        ev(~s{(area "s")}, e)
      end
    end

    test "is false for an unknown protocol rather than raising", %{e: e} do
      # A predicate that raises is not a predicate.
      assert ev("(satisfies? NoSuchProtocol 3)", e) == false
    end

    test "a partial extension cannot exist to be satisfied", %{e: _e} do
      # satisfies? demands every method. Probing whether it does revealed
      # that the question is unreachable through the public API:
      # extend_type REFUSES an incomplete extension outright, naming the
      # missing methods. That is the stronger guarantee — the invalid
      # state is unrepresentable rather than merely unsatisfying — so the
      # test pins the refusal instead of the predicate.
      BeamLisp.Multi.define_protocol("w28prims", "Partial", ["one", "two"])

      err =
        assert_raise RuntimeError, fn ->
          BeamLisp.Multi.extend_type("w28prims", "Partial", :float, %{
            "one" => fn _ -> :ok end
          })
        end

      assert err.message =~ ~s(missing methods: ["two"])
      refute BeamLisp.Multi.satisfies?("w28prims", "Partial", 1.5)

      # and a complete one satisfies
      BeamLisp.Multi.extend_type("w28prims", "Partial", :float, %{
        "one" => fn _ -> :ok end,
        "two" => fn _ -> :ok end
      })

      assert BeamLisp.Multi.satisfies?("w28prims", "Partial", 1.5)
    end

    test "works for records, deftypes and reify values", %{e: e} do
      # The navigator values Specter builds are reify values, so this is
      # the case the engine actually depends on.
      ev(
        """
        (ns w28prims)
        (defprotocol Nav (go [x]))
        (defrecord Rec [a])
        (extend-type Rec Nav (go [x] :rec))
        """,
        e
      )

      assert ev("(satisfies? Nav (->Rec 1))", e) == true
      assert ev("(satisfies? Nav 1)", e) == false

      # a reify satisfies the protocol it reifies, and its identity is
      # per-evaluation — two reifys are separately registered
      assert ev("(satisfies? Nav (reify Nav (go [x] :r)))", e) == true
    end

    test "resolves a protocol referred in from another namespace", %{e: e} do
      # Same resolution path extend-type uses; a bare name may belong to
      # somebody else.
      ev("(ns w28prims.p) (defprotocol Far (f [x])) (extend-type :integer Far (f [x] :yes))", e)

      assert ev(
               "(ns w28prims.q (:require [w28prims.p :refer :all])) (satisfies? Far 1)",
               e
             ) == true
    end
  end

  describe "extend-protocol reaches primitive type tags" do
    test "a keyword tag dispatches for a primitive value", %{e: e} do
      # Specter's :cljs branch extends its protocols to number/string
      # rather than to JVM classes, so primitive tags are the shape the
      # engine actually needs.
      assert ev(
               """
               (ns w28prims)
               (defprotocol Desc (desc [x]))
               (extend-protocol Desc
                 :integer (desc [x] :int)
                 :binary (desc [x] :str)
                 :vector (desc [x] :vec))
               [(desc 1) (desc "a") (desc [1 2])]
               """,
               e
             ) == v([:int, :str, :vec])
    end

    test "and satisfies? agrees with it", %{e: e} do
      ev(
        """
        (ns w28prims)
        (defprotocol D2 (d2 [x]))
        (extend-protocol D2 :integer (d2 [x] :int))
        """,
        e
      )

      assert ev("[(satisfies? D2 1) (satisfies? D2 :kw)]", e) == v([true, false])
    end
  end
end
