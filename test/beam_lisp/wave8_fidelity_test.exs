defmodule BeamLisp.Wave8FidelityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias BeamLisp.Vector

  setup do
    BeamLisp.init()
    BeamLisp.Env.in_ns("user")
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  describe "docstrings" do
    test "defn with a docstring records it as metadata" do
      eval(~s|(defn w8-fn "Squares a number." [n] (* n n))|)
      assert BeamLisp.Env.meta("user", "w8-fn") == {:ok, %{doc: "Squares a number."}}
    end

    test "defn without a docstring records no metadata" do
      eval("(defn w8-nodoc [x] x)")
      assert BeamLisp.Env.meta("user", "w8-nodoc") == :error
    end

    test "defn with a docstring still returns the fn value" do
      f = eval(~s|(defn w8-v "doc" [x] (* 2 x))|)
      assert is_function(f)
      assert apply(f, [21]) == 42
      assert eval("(w8-v 5)") == 10
    end

    test "def with a docstring records it and returns the value" do
      assert eval(~s|(def w8-const "A constant." 42)|) == 42
      assert BeamLisp.Env.meta("user", "w8-const") == {:ok, %{doc: "A constant."}}
    end

    test "defmacro with a docstring records it and still expands" do
      eval(~s|(defmacro w8-m "Returns its first body form." [& body] (first body))|)
      assert BeamLisp.Env.meta("user", "w8-m") == {:ok, %{doc: "Returns its first body form."}}
      assert eval("(w8-m 1 2 3)") == 1
    end

    test "redefining a var with a new docstring: the latest wins" do
      eval(~s|(defn w8-redef "first doc" [x] x)|)
      assert BeamLisp.Env.meta("user", "w8-redef") == {:ok, %{doc: "first doc"}}
      eval(~s|(defn w8-redef "second doc" [x] x)|)
      assert BeamLisp.Env.meta("user", "w8-redef") == {:ok, %{doc: "second doc"}}
    end

    test "defn with no clauses is a compile error" do
      assert_raise RuntimeError, ~r/expected at least one parameter vector/, fn ->
        eval("(defn w8-empty)")
      end
    end

    test "a lone string in defn (not followed by clauses) is an error" do
      assert_raise RuntimeError, ~r/expected a parameter vector, got a string literal/, fn ->
        eval(~s|(defn w8-lone "just a string")|)
      end
    end

    test "doc_string resolves a quoted symbol, a string, and a missing var" do
      eval(~s|(defn w8-greet "Says hi." [n] (str "hi " n))|)
      assert BeamLisp.Env.doc_string("user", {:symbol, "w8-greet"}) ==
               %{ns: "user", name: "w8-greet", doc: "Says hi."}

      assert BeamLisp.Env.doc_string("user", "w8-greet") ==
               %{ns: "user", name: "w8-greet", doc: "Says hi."}

      assert BeamLisp.Env.doc_string("user", {:symbol, "nope"}) == nil
    end

    test "doc_string resolves a var with no docstring to nil" do
      eval("(defn w8-plain [x] x)")
      assert BeamLisp.Env.doc_string("user", "w8-plain") == nil
    end

    test "doc prints a var's docstring in Clojure's shape" do
      eval(~s|(defn w8-doc "Squares n." [n] (* n n))|)
      out = capture_io(fn -> eval("(doc (quote w8-doc))") end)
      assert out =~ "-------------------------"
      assert out =~ "user/w8-doc"
      assert out =~ "Squares n."
    end

    test "doc resolves a core fn through the core fallback" do
      out = capture_io(fn -> eval("(doc (quote zipmap))") end)
      assert out =~ "core/zipmap"
      assert out =~ "Builds a map from parallel keys and values."
    end

    test "doc on a var without a docstring prints a friendly message" do
      eval("(defn w8-nd [x] x)")
      out = capture_io(fn -> eval("(doc (quote w8-nd))") end)
      assert out =~ "No doc found"
    end
  end

  describe "map destructuring in let" do
    test ":keys binds keyword keys by local name" do
      assert eval(~s|(let [{:keys [a b]} {:a 1 :b 2}] (+ a b))|) == 3
    end

    test ":keys with a kebab name binds the local verbatim" do
      assert eval(~s|(let [{:keys [b-c]} {:b-c 5}] b-c)|) == 5
    end

    test ":strs binds string keys" do
      assert eval(~s|(let [{:strs [s t]} {"s" "hi" "t" "yo"}] (str s t))|) == "hiyo"
    end

    test ":as binds the whole map" do
      assert eval(~s|(let [{:keys [a] :as whole} {:a 1 :b 2}] (get whole :b nil))|) == 2
    end

    test ":or supplies a default when a key is absent" do
      assert eval(~s|(let [{:keys [a b] :or {a 10 b 20}} {:a 1}] [a b])|) == Vector.new([1, 20])
    end

    test ":or keeps a present nil (Clojure's get semantics)" do
      assert eval(~s|(let [{:keys [a] :or {a 99}} {:a nil}] a)|) == nil
    end

    test "general form {local :key} binds from a keyword key" do
      assert eval(~s|(let [{x :x, y :y} {:x 1 :y 2}] (+ x y))|) == 3
    end

    test "general form with a string key" do
      assert eval(~s|(let [{x "x"} {"x" 7}] x)|) == 7
    end

    test "established {:key local} spelling still works" do
      assert eval(~s|(let [{:x x :y y} {:x 1 :y 2}] (+ x y))|) == 3
    end

    test "missing keys bind nil" do
      assert eval(~s|(let [{:keys [a b]} {:a 1}] [a b])|) == Vector.new([1, nil])
    end

    test "extra keys are ignored" do
      assert eval(~s|(let [{:keys [a]} {:a 1 :zz 2}] a)|) == 1
    end

    test "destructuring nil binds everything nil" do
      assert eval(~s|(let [{:keys [a b]} nil] [a b])|) == Vector.new([nil, nil])
    end

    test "nested vector pattern inside a map pattern" do
      assert eval(~s|(let [{[a b] :pair} {:pair [1 2]}] (+ a b))|) == 3
    end

    test "nested map pattern inside a vector pattern" do
      assert eval(~s|(let [[{:keys [a]} {b :b}] [{:a 1} {:b 2}]] (+ a b))|) == 3
    end

    test "nested map pattern inside a map pattern" do
      assert eval(~s|(let [{{:keys [x]} :inner} {:inner {:x 9}}] x)|) == 9
    end

    test "a :keys bind and a nested bind share one map pattern" do
      assert eval(~s|(let [{:keys [port] {:keys [enabled]} :tls} {:port 8080 :tls {:enabled true}}]
                 (str port enabled))|) == "8080true"
    end
  end

  describe "map destructuring in fn and defn params" do
    test "fn params destructure a map" do
      assert eval(~s|((fn [{:keys [a b]}] (+ a b)) {:a 1 :b 2})|) == 3
    end

    test "defn params destructure a map" do
      eval(~s|(defn w8-p [{:keys [a b] :or {b 10}}] (+ a b))|)
      assert eval("(w8-p {:a 1})") == 11
      assert eval("(w8-p {:a 1 :b 2})") == 3
    end

    test "defn params destructure via a linked call" do
      eval(~s|(defn w8-pair [{:keys [x]} {y :y}] (+ x y))|)
      assert eval("(w8-pair {:x 1} {:y 2})") == 3
    end

    test "defn param missing keys bind nil" do
      eval(~s|(defn w8-missing [{:keys [a b]}] (str a "-" b))|)
      assert eval(~s|(w8-missing {:a 1})|) == "1-"
    end

    test "defn param that is nil binds everything nil" do
      eval(~s|(defn w8-nilparam [{:keys [a]}] a)|)
      assert eval("(w8-nilparam nil)") == nil
    end

    test "nested destructuring in defn params" do
      eval(~s|(defn w8-nest [{:keys [cfg]} {[x y] :pt}] (str cfg x y))|)
      assert eval(~s|(w8-nest {:cfg 1} {:pt [2 3]})|) == "123"
    end
  end

  describe "map destructuring in loop bindings" do
    test "loop bindings destructure a map at entry" do
      assert eval(~s|(loop [{:keys [a] :or {a 5}} {}] a)|) == 5
    end

    test "recur re-supplies the pattern values" do
      assert eval(~s|(loop [i 3 {:keys [tag]} {:tag :x}]
                 (if (= i 0) tag (recur (dec i) {:tag :x})))|) == :x
    end
  end
end
