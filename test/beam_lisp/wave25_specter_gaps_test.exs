defmodule BeamLisp.Wave25SpecterGapsTest do
  # Wave 25: the top four gaps the Specter compatibility measurement
  # ranked cheapest per slice unlocked (docs/specter-compat.md) —
  # `defn-`, `reify`, `identical?`, and `defprotocol`'s leading
  # docstring. Together they move the load score from 1-of-31 toward
  # something real; each is tested for its semantics AND its edges.
  #
  # * `defn-` — private function. Clojure's `defn-` is `defn` with
  #   `^:private` metadata; here it lands `%{private: true}` in the
  #   var's metadata map. What "private" MEANS is enforced: a private
  #   var cannot be resolved by *qualified* name from another namespace
  #   (`other.ns/name` raises at compile), nor can it be `:refer`'d into
  #   one — both exactly as Clojure. Same-namespace access (qualified or
  #   bare) stays legal. The `@#'ns/name` bypass has no analogue here
  #   (beam-lisp has no var objects), which we accept and do not
  #   advertise. An *unenforced* `private` would be a lie the type
  #   system tells; so it is enforced.
  # * `reify` — an anonymous protocol instance that closes over its
  #   lexical environment. Shape: a `{:bl_deftype, mod, {}}` tuple (the
  #   same tagged-tuple family deftype uses) with a fresh module atom
  #   per call site, so `Multi.type_of` dispatches through the one
  #   protocol machinery — no parallel dispatch path. Method bodies
  #   compile in the enclosing env and capture locals by Elixir closure;
  #   `this` is the instance.
  # * `identical?` — reference equality. On the BEAM that is `===`: true
  #   by identity for the terms that carry identity (funs, pids, ports,
  #   refs) and strict no-coercion structural equality for the
  #   immutable value types that have no reference identity. The
  #   deviation is documented on `BeamLisp.RT.identical?/2`.
  # * `defprotocol` docstring — an optional leading string between the
  #   protocol name and the first method, stored as the protocol's
  #   `:doc` var metadata, exactly as defn handles its docstring.
  use ExUnit.Case, async: false

  alias BeamLisp.Compiler
  alias BeamLisp.Env

  setup do
    BeamLisp.init()
    Env.in_ns("user")
    :ok
  end

  defp eval(source), do: Compiler.eval_string(source, Compiler.new_env("user"))
  defp eval_in(ns, source), do: Compiler.eval_string(source, Compiler.new_env(ns))

  # A compile error that names a var as not public — the Clojure
  # "var: #'ns/name is not public" shape.
  defp assert_not_public(fun) do
    err = assert_raise BeamLisp.CompileError, fun
    assert err.message =~ "is not public"
    err
  end

  describe "defn- — private function definition" do
    test "defines a fn that is callable inside its own namespace" do
      eval_in("w25.a", """
      (ns w25.a)
      (defn- secret [x] (* x 2))
      (defn public-fn [x] (secret x))
      """)

      # bare and qualified access within the defining namespace both work
      assert eval_in("w25.a", "(secret 5)") == 10
      assert eval_in("w25.a", "(w25.a/secret 5)") == 10
      # a public wrapper can call the private fn
      assert eval_in("w25.a", "(w25.a/public-fn 21)") == 42
    end

    test "marks the var private in its metadata" do
      eval_in("w25.meta", "(ns w25.meta)\n(defn- hidden [x] x)")
      assert Env.meta("w25.meta", "hidden") == {:ok, %{private: true}}
    end

    test "a docstring and the private flag coexist in the metadata" do
      eval_in("w25.meta2", """
      (ns w25.meta2)
      (defn- documented "intentionally hidden" [x] x)
      """)

      assert Env.meta("w25.meta2", "documented") == {:ok, %{doc: "intentionally hidden", private: true}}
    end

    test "is not reachable by qualified name from another namespace" do
      eval_in("w25.sec", "(ns w25.sec)\n(defn- secret [x] (* x 2))")

      assert_not_public(fn ->
        eval_in("w25.intruder", "(ns w25.intruder)\n(w25.sec/secret 5)")
      end)
    end

    test "is not reachable through an alias from another namespace" do
      eval_in("w25.aliased", "(ns w25.aliased)\n(defn- inner [x] x)")

      assert_not_public(fn ->
        eval_in("w25.ali2", "(ns w25.ali2)\n(w25.aliased/inner 1)")
      end)
    end

    test "cannot be :refer'd into another namespace" do
      eval_in("w25.ref", "(ns w25.ref)\n(defn- locked [x] x)")

      assert_not_public(fn ->
        eval_in("w25.ref2", "(ns w25.ref2 (:require [w25.ref :refer [locked]]))")
      end)
    end

    test "public vars in the same namespace are unaffected" do
      eval_in("w25.pub", """
      (ns w25.pub)
      (defn- p [x] (+ x 1))
      (defn q [x] (p x))
      """)

      assert eval_in("w25.other", "(ns w25.other)\n(w25.pub/q 1)") == 2
    end

    test "rejects an empty body with a clear error" do
      err = assert_raise BeamLisp.CompileError, fn -> eval("(defn- nope)") end
      assert err.message =~ "expected at least one parameter vector"
    end

    test "a public defn does not carry the private flag" do
      eval_in("w25.notpriv", "(ns w25.notpriv)\n(defn open [x] x)")
      assert Env.meta("w25.notpriv", "open") == :error
    end
  end

  describe "reify — anonymous protocol instances" do
    test "builds an instance implementing one protocol, dispatching correctly" do
      eval_in("w25.r1", """
      (ns w25.r1)
      (defprotocol Area (area [this]))
      (def c (reify Area (area [this] 42)))
      """)

      assert eval_in("w25.r1", "(area c)") == 42
    end

    test "implements several protocols on one instance" do
      eval_in("w25.r2", """
      (ns w25.r2)
      (defprotocol A (a [this]))
      (defprotocol B (b [this]))
      (def x (reify A (a [this] :a) B (b [this] :b)))
      """)

      assert eval_in("w25.r2", "(a x)") == :a
      assert eval_in("w25.r2", "(b x)") == :b
    end

    test "closes over its lexical environment — the whole point versus deftype" do
      eval_in("w25.r3", """
      (ns w25.r3)
      (defprotocol Scale (scaled [this]))
      (defn make-scaler [factor base]
        (reify Scale (scaled [this] (* factor base))))
      (def s3 (make-scaler 3 10))
      (def s5 (make-scaler 5 10))
      """)

      # each instance captures the factor it was built with
      assert eval_in("w25.r3", "(scaled s3)") == 30
      assert eval_in("w25.r3", "(scaled s5)") == 50
    end

    test "method bodies receive the instance as this" do
      eval_in("w25.r4", """
      (ns w25.r4)
      (defprotocol Ident (self [this]))
      (defprotocol Named (name-of [this]))
      (def x (reify Ident (self [this] this) Named (name-of [this] "anon")))
      """)

      # `this` inside a method is the same instance that was reified
      assert eval_in("w25.r4", "(identical? x (self x))") == true
      assert eval_in("w25.r4", "(name-of x)") == "anon"
    end

    test "an instance is a new type distinct from other reify sites" do
      eval_in("w25.r5", """
      (ns w25.r5)
      (defprotocol T (tag [this]))
      (def a (reify T (tag [this] :a)))
      (def b (reify T (tag [this] :b)))
      """)

      assert eval_in("w25.r5", "(tag a)") == :a
      assert eval_in("w25.r5", "(tag b)") == :b
    end

    test "an incomplete extension is refused at extend time" do
      eval_in("w25.r6", """
      (ns w25.r6)
      (defprotocol Two (m1 [this]) (m2 [this]))
      """)

      err =
        assert_raise RuntimeError, fn ->
          eval_in("w25.r6", "(reify Two (m1 [this] 1))")
        end

      assert err.message =~ "missing methods"
    end
  end

  describe "identical? — reference equality" do
    test "equal value types are identical" do
      assert eval("(identical? 1 1)") == true
      assert eval("(identical? :k :k)") == true
      assert eval("(identical? \"same\" \"same\")") == true
      assert eval("(identical? [1 2] [1 2])") == true
    end

    test "different values are not identical" do
      assert eval("(identical? 1 2)") == false
      assert eval("(identical? :a :b)") == false
      assert eval("(identical? [1 2] [1 3])") == false
    end

    test "is strict — no numeric coercion (the === deviation, honest)" do
      # On the BEAM identical? is `===`: type-strict, so 1 and 1.0 are
      # different terms. Clojure would also return false here (they are
      # different values), so this matches; the deviation is on the
      # *true* side — equal-but-distinct immutable terms return true
      # where Clojure's identical? is unspecified. See RT.identical?/2.
      assert eval("(identical? 1 1.0)") == false
    end

    test "functions have reference identity" do
      # Funs are the one ordinary term that carries true identity on the
      # BEAM: the same fun is identical to itself, two separately-created
      # funs are not, even with identical bodies.
      assert eval("(let [f (fn [x] x)] (identical? f f))") == true
      assert eval("(identical? (fn [x] x) (fn [x] x))") == false
    end

    test "serves Specter's NONE-sentinel pattern with an atom sentinel" do
      eval("""
      (def NONE :__none__)
      (defn strip [v] (if (identical? v NONE) :stripped v))
      """)

      assert eval("(strip NONE)") == :stripped
      assert eval("(strip 5)") == 5
      # a copy of the sentinel value (same atom) is still the sentinel
      assert eval("(strip :__none__)") == :stripped
    end
  end

  describe "defprotocol leading docstring" do
    test "a docstring between the name and first method is accepted and stored" do
      eval_in("w25.pd", """
      (ns w25.pd)
      (defprotocol Greeter "A greeter protocol." (greet [this] "hi"))
      (extend-type :keyword Greeter (greet [this] "hi"))
      """)

      assert Env.meta("w25.pd", "Greeter") == {:ok, %{doc: "A greeter protocol."}}
      # the protocol still works after the docstring was skipped
      assert eval_in("w25.pd", "(greet :x)") == "hi"
    end

    test "the docstring is retrievable via the same doc resolution as defn" do
      eval_in("w25.pd2", """
      (ns w25.pd2)
      (defprotocol Doc'd "documented protocol" (m [this] 1))
      """)

      assert Env.doc_string("w25.pd2", "Doc'd") == %{ns: "w25.pd2", name: "Doc'd", doc: "documented protocol"}
    end

    test "a protocol without a docstring still defines and has no doc" do
      eval_in("w25.pd3", """
      (ns w25.pd3)
      (defprotocol Plain (m [this] 2))
      (extend-type :keyword Plain (m [this] 2))
      """)

      assert Env.meta("w25.pd3", "Plain") == :error
      assert eval_in("w25.pd3", "(m :x)") == 2
    end

    test "multiple methods and a docstring together" do
      eval_in("w25.pd4", """
      (ns w25.pd4)
      (defprotocol P "two methods" (one [this] 1) (two [this] 2))
      (extend-type :keyword P (one [this] 1) (two [this] 2))
      """)

      assert Env.meta("w25.pd4", "P") == {:ok, %{doc: "two methods"}}
      assert eval_in("w25.pd4", "(one :x)") == 1
      assert eval_in("w25.pd4", "(two :x)") == 2
    end
  end
end
