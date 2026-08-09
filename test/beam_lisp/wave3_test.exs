defmodule BeamLisp.Wave3Test do
  use ExUnit.Case, async: false

  alias BeamLisp.Vector

  setup do
    BeamLisp.init()
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  describe "vectors" do
    test "a vector is not a list" do
      assert %Vector{} = eval("[1 2 3]")
      refute eval("[1 2 3]") == [1, 2, 3]
    end

    test "conj appends to vectors, prepends to lists" do
      assert eval("(conj [1 2] 3)") == Vector.new([1, 2, 3])
      assert eval("(conj '(1 2) 3)") == [3, 1, 2]
    end

    test "seq fns accept vectors" do
      assert eval("(first [1 2])") == 1
      assert eval("(rest [1 2 3])") == [2, 3]
      assert eval("(count [1 2 3])") == 3
      assert eval("(empty? [])") == true
    end

    test "nth is O(1) and lenient" do
      assert eval("(let [[a b] [10 20 30]] (+ a b))") == 30
    end

    test "vectors are enumerable for Elixir interop" do
      assert eval("(Enum/sum [1 2 3])") == 6
      assert eval("(Enum/map [1 2 3] (fn [x] (* x 2)))") == [2, 4, 6]
    end

    test "apply accepts vectors" do
      assert eval("(apply (fn [x y] (+ x y)) [3 4])") == 7
    end

    test "quote yields a vector for vector forms" do
      assert eval("'[1 2 3]") == Vector.new([1, 2, 3])
    end

    test "vectors print in Clojure syntax" do
      assert eval("(pr-str [1 :two \"three\"])") == ~s([1 :two "three"])
    end
  end

  describe "syntax-quote" do
    test "quotes structure without evaluation" do
      # A name that resolves where the template was WRITTEN is emitted
      # qualified, as Clojure does -- that is what lets a library macro call
      # its own helper from another namespace. A name that resolves to nothing
      # is a fresh name the template introduces and stays bare.
      # Pin the namespace explicitly: `Env.current_ns` is process-global and
      # survives across evaluations, so an earlier test that ran an example
      # can leave it pointing anywhere. The qualification is BY the current
      # namespace, so this assertion would otherwise depend on test order.
      BeamLisp.Env.in_ns("user")
      eval("(def w3-known 1)")
      assert eval("`(w3-known w3-unknown)") == [{:symbol, "user/w3-known"}, {:symbol, "w3-unknown"}]
    end

    test "a macro name inside a template stays bare" do
      # Macros are resolved by the expander, which already searches the
      # writing namespace and core. Qualifying one sent it down the ordinary
      # var path, where it was invoked as a function -- which broke every
      # vendored macro nesting `when`/`let`.
      assert eval("`(when true 1)") == [{:symbol, "when"}, true, 1]
    end

    test "unquote evaluates" do
      assert eval("(def x 42) `(w3-u1 ~x w3-u2)") ==
               [{:symbol, "w3-u1"}, 42, {:symbol, "w3-u2"}]
    end

    test "splicing flattens" do
      assert eval("(def xs '(2 3)) `(1 ~@xs 4)") == [1, 2, 3, 4]
    end

    test "syntax-quoted vectors stay vectors" do
      assert eval("`[1 ~(+ 1 1)]") == Vector.new([1, 2])
    end

    test "~@ outside a list is an error" do
      assert_raise RuntimeError, ~r/only valid inside/, fn ->
        eval("`~@1")
      end
    end
  end

  describe "defmacro" do
    test "unless" do
      assert eval("""
             (defmacro unless [c t f] `(if (not ~c) ~t ~f))
             (unless (= 1 2) :yes :no)
             """) == :yes
    end

    test "macro args arrive unevaluated" do
      assert eval("""
             (defmacro quoted-second [form] `(quote ~(second form)))
             (quoted-second (a b c))
             """) == {:symbol, "b"}
    end

    test "infix via unquoted operator" do
      assert eval("(defmacro infix [a op b] `(~op ~a ~b)) (infix 2 + 3)") == 5
    end

    test "variadic macro with splicing" do
      assert eval("(defmacro my-list [& xs] `(list ~@xs)) (my-list 1 2 3)") == [1, 2, 3]
    end

    test "macro producing vector params works (vector/list distinction)" do
      assert eval("""
             (defmacro defconst [name v] (list (quote def) name v))
             (defconst answer 42)
             answer
             """) == 42
    end

    test "a macro must be defined before use" do
      assert_raise RuntimeError, ~r/undefined var/, fn ->
        eval("(never-defined-macro 1 2)")
      end
    end
  end
end
