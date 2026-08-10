defmodule BeamLisp.Wave28NsReferTest do
  # Four bugs, all found by laying Specter's fixtures out the way its own
  # source is laid out — one namespace per upstream file, referring each
  # other as Clojure code actually does. Every one of them was invisible
  # under the co-load convention the compat harness had been using, which
  # is the lesson: a measurement's SCAFFOLDING can hide the very gaps the
  # measurement exists to find.
  use ExUnit.Case, async: false

  setup do
    BeamLisp.init()
    :ok
  end

  defp env(ns), do: BeamLisp.Compiler.new_env(ns)
  defp ev(src, env), do: BeamLisp.Compiler.eval_string(src, env)

  describe "a namespace exists from its (ns …) form, not its first def" do
    test "an empty namespace can be required" do
      # Existence used to be inferred by probing ETS for a var, so a
      # namespace holding nothing yet simply did not exist and the
      # require fell through to a disk search that could not find it.
      e = env("user")
      ev("(ns w28.hollow)", e)

      assert BeamLisp.Env.ns_exists?("w28.hollow")
      assert ev("(ns w28.hollow.user (:require [w28.hollow :as h])) :ok", e) == :ok
    end

    test "a namespace can be required before its vars are defined" do
      # The REPL-shaped sequence, and the shape of any two namespaces
      # that reference each other: declare, require, then populate.
      e = env("user")
      ev("(ns w28.later)", e)
      assert ev("(ns w28.later.user (:require [w28.later :as l])) :ok", e) == :ok

      ev("(ns w28.later) (defn f [] 42)", e)
      assert ev("(ns w28.later.user) (l/f)", e) == 42
    end

    test "a namespace that exists nowhere still raises, and names the search path" do
      # The fix must not turn a genuine typo into silence.
      e = env("user")

      err =
        assert_raise RuntimeError, fn ->
          ev("(ns w28.typo (:require [w28.no.such.ns :as n]))", e)
        end

      assert err.message =~ "namespace not found: w28.no.such.ns"
      assert err.message =~ "searched:"
    end

    test "a real file on disk still wins over an in-memory namespace of the same name" do
      # Declaring a namespace must not shadow a requirable file — the
      # loader consults the disk first and treats in-memory existence
      # only as permission to skip the raise.
      e = env("user")
      assert ev("(ns w28.diskcheck (:require [optics :as o])) :ok", e) == :ok
      # optics really loaded, rather than being waved through as "exists"
      assert BeamLisp.Env.local_var?("optics", "compose-optic")
    end
  end

  describe ":refer :all" do
    setup do
      e = env("user")

      ev(
        """
        (ns w28.src)
        (defn pub [x] (* x 3))
        (defmacro twice [e] `(+ ~e ~e))
        (defn- hidden [] :nope)
        """,
        e
      )

      {:ok, e: e}
    end

    test "refers every public var, functions and macros alike", %{e: e} do
      ev("(ns w28.all (:require [w28.src :refer :all]))", e)

      assert ev("(ns w28.all) (pub 5)", e) == 15
      # A macro has to survive the blanket refer too: it is expanded by a
      # different path than an ordinary var, and referring only values
      # would leave `(twice 4)` looking like an undefined call.
      assert ev("(ns w28.all) (twice 4)", e) == 8
    end

    test "does not refer private vars", %{e: e} do
      # The blanket form must not be a way around privacy that the
      # explicit form refuses.
      ev("(ns w28.allpriv (:require [w28.src :refer :all]))", e)

      assert_raise RuntimeError, ~r/undefined var: w28\.allpriv\/hidden/, fn ->
        ev("(ns w28.allpriv) (hidden)", e)
      end
    end

    test "explicit :refer still refuses a private var at compile time", %{e: e} do
      assert_raise BeamLisp.CompileError, ~r/var w28\.src\/hidden is not public/, fn ->
        ev("(ns w28.explicit (:require [w28.src :refer [hidden]]))", e)
      end
    end

    test "combines with :as", %{e: e} do
      assert ev(
               "(ns w28.both (:require [w28.src :as s :refer :all])) [(s/pub 1) (pub 1)]",
               e
             ) == BeamLisp.Vector.new([3, 3])
    end

    test "is a snapshot: vars defined after the refer do not appear", %{e: e} do
      # Clojure's :refer :all is resolved when the ns form runs, not
      # continuously. Pinning the behaviour so it cannot silently become
      # a live view later.
      ev("(ns w28.snap (:require [w28.src :refer :all]))", e)
      ev("(ns w28.src) (defn added-later [] :late)", e)

      assert_raise RuntimeError, ~r/undefined var/, fn ->
        ev("(ns w28.snap) (added-later)", e)
      end
    end
  end

  describe "protocols resolve through refers" do
    test "extend-type finds a protocol that was referred in" do
      # This failed by INVENTING a second, empty protocol under the
      # extending namespace's name. The extension registered against it
      # happily, and the failure surfaced much later as "no
      # implementation of method area" — far from the cause.
      e = env("user")
      ev("(ns w28.proto) (defprotocol Shape (area [s]))", e)

      ev(
        """
        (ns w28.impl (:require [w28.proto :refer :all]))
        (defrecord Circle [r])
        (extend-type Circle Shape (area [s] (* 3 (:r s) (:r s))))
        """,
        e
      )

      assert ev("(ns w28.impl) (area (->Circle 2))", e) == 12
      # and the extension landed on the ORIGINAL protocol, so a caller in
      # the defining namespace dispatches to it too
      assert ev("(ns w28.proto) (area (w28.impl/->Circle 2))", e) == 12
    end

    test "a locally defined name still shadows a referred one" do
      # The refer is consulted only when the name is not local, so
      # defining your own protocol of the same name keeps working.
      e = env("user")
      ev("(ns w28.p2) (defprotocol Sized (sized [s]))", e)

      ev(
        """
        (ns w28.p2user (:require [w28.p2 :refer :all]))
        (defprotocol Sized (sized [s]))
        (defrecord Box [n])
        (extend-type Box Sized (sized [s] (:n s)))
        """,
        e
      )

      assert ev("(ns w28.p2user) (sized (->Box 7))", e) == 7
    end
  end

  describe "syntax-quote qualifies to the namespace that OWNS the var" do
    test "a referred var expands to its home namespace, not the referrer" do
      # `(:require [p :refer :all])` then `` `Thing `` in a macro used to
      # expand to `referrer/Thing`, a name that resolves nowhere. The var
      # lives in p, and that is where the expansion site must look.
      e = env("user")
      ev("(ns w28.home) (def marker :from-home)", e)

      ev(
        """
        (ns w28.writer (:require [w28.home :refer :all]))
        (defmacro get-marker [] `marker)
        """,
        e
      )

      # expanded and called from a THIRD namespace that never required
      # w28.home — only correct qualification can make this resolve
      # NB: a beam-lisp keyword keeps its hyphen as-is, so the atom is
      # :"from-home" and not :from_home.
      assert ev("(ns w28.caller (:require [w28.writer :refer :all])) (get-marker)", e) ==
               :"from-home"
    end

    test "a locally defined var still qualifies to the writing namespace" do
      e = env("user")

      ev(
        """
        (ns w28.local)
        (def own :mine)
        (defmacro get-own [] `own)
        """,
        e
      )

      assert ev("(ns w28.lcaller (:require [w28.local :refer :all])) (get-own)", e) == :mine
    end
  end
end
