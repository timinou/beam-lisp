defmodule BeamLisp.Wave11MultiTest do
  use ExUnit.Case, async: false

  alias BeamLisp.Env

  setup do
    BeamLisp.init()
    Env.in_ns("user")
    # multi.bl holds the hierarchy helpers; load it so tests can use
    # multi/derive, multi/isa? (multimethod/protocol special forms are
    # in the compiler, so they need no load).
    BeamLisp.run_file("priv/multi.bl")
    Env.in_ns("user")
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  describe "defmulti / defmethod" do
    test "dispatch on a keyword extracts the method by dispatch value" do
      eval("""
      (defmulti area-m :shape)
      (defmethod area-m :circle [s] (* 3.14159 (:r s) (:r s)))
      (defmethod area-m :rect [s] (* (:w s) (:h s)))
      """)

      assert eval("(area-m {:shape :circle :r 2})") == 3.14159 * 4
      assert eval("(area-m {:shape :rect :w 3 :h 4})") == 12
    end

    test "the dispatch fn receives all args; multi-arg dispatch works" do
      eval("""
      (defn kind-of [o] (:kind o))
      (defmulti speak-to (fn [speaker listener] (kind-of listener)))
      (defmethod speak-to :human [s l] (str "hello " (:name l)))
      (defmethod speak-to :robot [s l] "beep boop")
      """)

      assert eval("(speak-to {:kind :dog :name \"rex\"} {:kind :human :name \"alice\"})") ==
               "hello alice"

      assert eval("(speak-to {:kind :cat} {:kind :robot})") == "beep boop"
    end

    test "a vector dispatch value keys a method (structurally equal vectors match)" do
      eval("""
      (defn kind-of [o] (:kind o))
      (defmulti collide-m (fn [a b] [(kind-of a) (kind-of b)]))
      (defmethod collide-m [:asteroid :ship] [a b] :boom)
      (defmethod collide-m :default [& xs] :nothing)
      """)

      assert eval("(collide-m {:kind :asteroid} {:kind :ship})") == :boom
      # A structurally-equal vector built at call time must still hit.
      assert eval("(collide-m {:kind :asteroid} {:kind :ship :extra 1})") == :boom
      assert eval("(collide-m {:kind :ship} {:kind :ship})") == :nothing
    end

    test ":default is the fallback for any unmatched dispatch value" do
      eval("""
      (defmulti f-default :tag)
      (defmethod f-default :a [x] :A)
      (defmethod f-default :default [x] :fallback)
      """)

      assert eval("(f-default {:tag :a})") == :A
      assert eval("(f-default {:tag :zzz})") == :fallback
    end

    test "missing method (and no :default) raises a clear error" do
      eval("(defmulti f-missing :tag) (defmethod f-missing :a [x] :A)")

      err = assert_raise RuntimeError, fn -> eval("(f-missing {:tag :nope})") end
      assert Exception.message(err) =~ "user/f-missing"
      assert Exception.message(err) =~ ":nope"
    end

    test "defmethod adds and replaces methods without touching the others" do
      eval("""
      (defmulti m-repl :id)
      (defmethod m-repl :a [x] :A)
      (defmethod m-repl :b [x] :B)
      (defmethod m-repl :b [x] :B2)
      (defmethod m-repl :c [x] :C)
      """)

      assert eval("(m-repl {:id :a})") == :A
      assert eval("(m-repl {:id :b})") == :B2
      assert eval("(m-repl {:id :c})") == :C
    end

    test "re-defining defmulti preserves existing methods (CLJ-1351)" do
      eval("""
      (defmulti m-pres :id)
      (defmethod m-pres :a [x] :A)
      """)

      # Re-issue defmulti with the same dispatch fn: methods survive.
      eval("(defmulti m-pres :id)")
      assert eval("(m-pres {:id :a})") == :A

      # Redefining with a *different* dispatch fn also keeps methods.
      eval("(defmulti m-pres (fn [x] (:other x)))")
      eval("(defmethod m-pres :z [x] :Z)")
      assert eval("(m-pres {:other :z})") == :Z
      assert eval("(m-pres {:other :a})") == :A
    end

    test "variadic method bodies work" do
      eval("""
      (defmulti total-v (fn [m & more] (:which m)))
      (defmethod total-v :all [cfg & xs] (reduce + 0 xs))
      (defmethod total-v :first [cfg x & more] x)
      """)

      assert eval("(total-v {:which :all} 1 2 3 4)") == 10
      assert eval("(total-v {:which :first} 7 8 9)") == 7
    end

    test "a multimethod defined in one ns is callable from another after require" do
      eval("""
      (ns w11.lib)
      (defmulti greet :lang)
      (defmethod greet :en [m] (str "hi " (:name m)))
      (defmethod greet :es [m] (str "hola " (:name m)))
      (ns w11.app (:require [w11.lib :as lib]))
      """)

      assert eval("(lib/greet {:lang :en :name \"bob\"})") == "hi bob"
      assert eval("(lib/greet {:lang :es :name \"bob\"})") == "hola bob"
    end

    test "defmethod resolves the multi through an alias" do
      eval("""
      (ns w11.lib2)
      (defmulti m :id)
      (defmethod m :a [x] :A)
      (ns w11.app2 (:require [w11.lib2 :as l]))
      (defmethod l/m :b [x] :B)
      """)

      assert eval("(l/m {:id :b})") == :B
      assert eval("(l/m {:id :a})") == :A
    end

    test "defmulti supports a docstring (stored as var metadata)" do
      eval("(defmulti m-doc \"docstring\" :id)")
      eval("(defmethod m-doc :a [x] :A)")
      assert eval("(m-doc {:id :a})") == :A

      {:ok, %{doc: "docstring"}} = Env.meta("user", "m-doc")
    end
  end

  describe "hierarchies (derive / isa?)" do
    test "derive + isa? walk the parent chain" do
      eval("""
      (multi/derive :cat :animal)
      (multi/derive :animal :living)
      """)

      assert eval("(multi/isa? :cat :animal)") == true
      assert eval("(multi/isa? :cat :living)") == true
      assert eval("(multi/isa? :animal :cat)") == false
      assert eval("(multi/isa? :cat :cat)") == true
      assert eval("(multi/underive :cat :animal)") == false
      assert eval("(multi/isa? :cat :animal)") == false
    end

    test "a dispatch value derived from a method key still hits that method" do
      eval("""
      (multi/derive :cat :animal)
      (defmulti h-speak :kind)
      (defmethod h-speak :animal [a] :generic)
      (defmethod h-speak :cat [a] :meow)
      """)

      assert eval("(h-speak {:kind :cat})") == :meow
      assert eval("(h-speak {:kind :animal})") == :generic
    end
  end

  describe "protocols (defprotocol / extend-type)" do
    test "methods dispatch on the type tag of the first argument" do
      eval("""
      (defprotocol Greet (greet-p [this]) (describe-p [this]))
      (extend-type :vector Greet
        (greet-p [v] (str "vector of " (count v)))
        (describe-p [v] "a vector"))
      (extend-type :map Greet
        (greet-p [m] "map")
        (describe-p [m] "a map"))
      """)

      assert eval("(greet-p [1 2 3])") == "vector of 3"
      assert eval("(describe-p {:a 1})") == "a map"
    end

    test "extend-protocol fills several types at once" do
      eval("""
      (defprotocol Prot (prot-fn [x]))
      (extend-protocol Prot
        :list (prot-fn [l] (str "list " (count l)))
        :integer (prot-fn [n] (str "int " n))
        :binary (prot-fn [s] (str "str " s)))
      """)

      assert eval("(prot-fn '(1 2))") == "list 2"
      assert eval("(prot-fn 5)") == "int 5"
      assert eval("(prot-fn \"hi\")") == "str hi"
    end

    test "extending a type after the fact keeps earlier calls working" do
      eval("""
      (defprotocol Area-p (area-p [x]))
      (extend-type :integer Area-p (area-p [n] (* n n)))
      """)

      assert eval("(area-p 3)") == 9
      # New type extended later; old calls unaffected.
      eval("(extend-type :vector Area-p (area-p [v] (reduce + 0 v)))")
      assert eval("(area-p [1 2 3])") == 6
      assert eval("(area-p 4)") == 16
    end

    test "a protocol method with no implementation for a type raises clearly" do
      eval("""
      (defprotocol Q-p (q-p [x]))
      (extend-type :vector Q-p (q-p [v] :vec))
      """)

      assert_raise RuntimeError, ~r/No implementation of method q-p/, fn -> eval("(q-p 5)") end
    end

    test "the protocol descriptor var is a tagged value" do
      eval("(defprotocol D-p (d-p [x])) (extend-type :vector D-p (d-p [v] :ok))")
      assert eval("(d-p [1])") == :ok
    end
  end
end
