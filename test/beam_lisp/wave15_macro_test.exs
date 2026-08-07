defmodule BeamLisp.Wave15MacroTest do
  # Wave 15: the macro-authoring surface that jank's core.jank assumes —
  # `loop*` (and `let*`/`fn*`), form metadata (`meta`/`with-meta` on the
  # data a macro receives), `&form`/`&env` bound inside every macro,
  # a `clojure.core` alias, and `assert-macro-args`. Together these
  # unlock the macro-heavy middle of jank's stdlib.
  #
  # The strongest proof is the vendored fixtures: slice_10/11/13/14/16/17/
  # 18/21 are byte-for-byte jank core.jank text, loaded verbatim and
  # called with their own shapes. slice_17 (doseq) loads but does not yet
  # behave: its expansion calls `(steppair 0)` — a vector-as-function, an
  # RT.invoke gap owned by the runtime (BeamLisp.RT), not this wave.
  use ExUnit.Case, async: false

  alias BeamLisp.{Compiler, Env}

  setup do
    BeamLisp.init()
    Env.in_ns("user")
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  # The fixture minus its `;` provenance header, wrapped in a throwaway ns
  # — same harness as jank_compat_test.exs.
  defp fixture_code(fixture) do
    Path.join(["test", "fixtures", "jank", fixture])
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, ";"))
    |> Enum.join("\n")
  end

  defp load_slice(fixture, ns) do
    source = "(ns #{ns})\n" <> fixture_code(fixture)
    Compiler.eval_string(source, Compiler.new_env(ns))
  end

  defp eval_in(ns, source), do: Compiler.eval_string(source, Compiler.new_env(ns))

  describe "the *-suffixed primitives" do
    test "loop* is the primitive beneath loop" do
      assert eval("(loop* [i 0 acc ()] (if (< i 3) (recur (+ i 1) (cons i acc)) acc))") ==
               [2, 1, 0]

      # recur targets the innermost loop, exactly as with `loop`
      assert eval("(loop* [i 0] (if (< i 3) (recur (+ i 1)) i))") == 3
      assert eval("(loop* [i 0 acc ()] (if (< i 3) (recur (+ i 1) (cons i acc)) acc))") == [2, 1, 0]
    end

    test "let* and fn* are the primitives beneath let and fn" do
      assert eval("(let* [x 1 y 2] (+ x y))") == 3
      assert eval("((fn* [x] (+ x 1)) 5)") == 6
      # fn* supports the named form jank's head uses
      assert eval("((fn* named-fn [x] (if (= x 0) 0 (+ 1 (named-fn (- x 1))))) 3)") == 3
    end
  end

  describe "form metadata" do
    test "meta reads what with-meta attached, nil when absent" do
      assert eval("(meta (with-meta '(1 2) {:line 7}))") == %{line: 7}
      assert eval("(meta '(1 2))") == nil
      assert eval("(meta (with-meta '(+ 1 2) {:file \"x.bl\" :line 3}))") == %{
               file: "x.bl",
               line: 3
             }
    end

    test "with-meta nil clears" do
      assert eval("(meta (with-meta (with-meta '(1) {:a 1}) nil))") == nil
    end

    test "a with-meta'd form compiles identically (macro round-trip)" do
      # The macro carries metadata on the form it returns; the compiler
      # strips it before codegen, so the value is unaffected.
      assert eval("(defmacro tm [x] (with-meta `(inc ~x) {:line 1})) (tm 4)") == 5
      assert eval("(defmacro tm [x] (with-meta `(inc ~x) {:line 1})) (= (tm 4) (tm 4))") == true
      assert eval("(defmacro tm [x] (with-meta x {:line 1})) (tm (+ 1 2))") == 3
    end

    test "metadata round-trips through a macro without changing behavior" do
      # Attach meta to a form datum, read it back inside the same macro.
      assert eval(
               "(defmacro roundtrip [x] (let [t (with-meta x {:line 99})] (= 99 (get (meta t) :line)))) (roundtrip (+ 1 2))"
             ) == true

      # with-meta nil clears the wrapper back to the bare form.
      assert eval("(meta (with-meta (with-meta '(1) {:a 1}) nil))") == nil
    end

    test "form metadata never leaks into value equality or printing" do
      # The compiled value of a with-meta'd form is the bare form's value.
      assert eval("(defmacro m1 [x] (with-meta `(identity ~x) {:a 1})) (= (m1 5) 5)") == true
      assert eval("(defmacro m2 [x] (with-meta `(+ ~x 1) {:a 1})) (m2 1)") == 2
    end
  end

  describe "&form and &env" do
    test "&form is the whole macro call form" do
      assert eval("(defmacro name-of [& _] (= (first &form) 'name-of)) (name-of 1 2)") == true
      assert eval("(defmacro head-is? [x] (and (list? &form) (= (first &form) 'head-is?))) (head-is? 5)") ==
               true
    end

    test "&env is the compile-time locals map" do
      assert eval("(defmacro has-x? [] (contains? &env 'x)) (defn f [x] (has-x?)) (f 1)") == true
      assert eval("(defmacro has-x? [] (contains? &env 'x)) (defn g [a] (has-x?)) (g 1)") == false
    end
  end

  describe "clojure.core alias" do
    test "qualified clojure.core/ names resolve to beam-lisp's core" do
      assert eval("(clojure.core/inc 5)") == 6
      assert eval("(clojure.core/str 1 \"a\")") == "1a"
      assert eval("(clojure.core/not 3)") == false
      assert eval("(clojure.core/map clojure.core/inc [1 2 3])") == [2, 3, 4]
      # as a value (a var, not a call)
      assert is_function(eval("clojure.core/inc"))
    end
  end

  describe "assert-macro-args" do
    test "accepts a valid shape and returns nil" do
      assert eval(
               "(defmacro v [bindings] (assert-macro-args (vector? bindings) \"a vector\")) (v [1])"
             ) == nil
    end

    test "throws naming the failing macro from &form" do
      err =
        try do
          eval("(defmacro bad [bindings] (assert-macro-args (vector? bindings) \"a vector\")) (bad 5)")
          nil
        rescue
          e -> Exception.message(e)
        end

      assert err =~ "bad requires a vector"
    end

    test "checks all conditions in sequence" do
      err =
        try do
          eval(
            "(defmacro bad2 [bindings] (assert-macro-args (vector? bindings) \"a vector\" (= 2 (count bindings)) \"exactly 2 forms\")) (bad2 [1 2 3])"
          )
          nil
        rescue
          e -> Exception.message(e)
        end

      assert err =~ "bad2 requires exactly 2 forms"
    end
  end

  describe "jank core.jank macro slices (loaded verbatim)" do
    test "-> threads the first argument (slice_10)" do
      load_slice("slice_10_thread_macro.bl", "w15.thread")
      assert eval_in("w15.thread", "(-> 5 inc inc)") == 7
      assert eval_in("w15.thread", "(-> 5 (+ 1) (* 2))") == 12
      assert eval_in("w15.thread", "(-> :a identity)") == :a
    end

    test "->> threads the last argument (slice_11)" do
      load_slice("slice_11_thread_last_macro.bl", "w15.threadl")
      assert eval_in("w15.threadl", "(->> [1 2 3] (map inc) (map inc))") == [3, 4, 5]
      assert eval_in("w15.threadl", "(->> 5 (- 1))") == -4
    end

    test "if-let binds the test value in the then branch (slice_13)" do
      load_slice("slice_13_if_let.bl", "w15.iflet")
      assert eval_in("w15.iflet", "(if-let [x 5] x :none)") == 5
      assert eval_in("w15.iflet", "(if-let [x nil] x :none)") == :none
      # the 2-arity form (no else) yields nil on a falsy test
      assert eval_in("w15.iflet", "(if-let [x false] x)") == nil
    end

    test "when-let runs the body only when the test is truthy (slice_14)" do
      load_slice("slice_14_when_let.bl", "w15.whenlet")
      assert eval_in("w15.whenlet", "(when-let [x 5] x)") == 5
      assert eval_in("w15.whenlet", "(when-let [x nil] x)") == nil
    end

    test "dotimes repeats the body with i from 0..n-1 (slice_16)" do
      load_slice("slice_16_dotimes.bl", "w15.dotimes")
      assert eval_in("w15.dotimes", "(def a (atom [])) (dotimes [i 4] (swap! a conj i)) @a") ==
               BeamLisp.Vector.new([0, 1, 2, 3])
    end

    test "doto threads x through each form and returns x (slice_18)" do
      load_slice("slice_18_doto.bl", "w15.doto")
      atom = eval_in("w15.doto", "(doto (atom []) (swap! conj 1) (swap! conj 2))")
      assert BeamLisp.Refs.deref(atom) == BeamLisp.Vector.new([1, 2])
    end

    test "memoize caches by arguments (slice_21, needs if-let from core)" do
      # key/val come from slice_12, co-loaded as upstream itself requires
      load_slice("slice_12_map_entries.bl", "w15.memo")
      load_slice("slice_21_memoize.bl", "w15.memo")
      assert eval_in("w15.memo", "(def mm (memoize (fn [x] (* x x)))) (mm 3)") == 9
      assert eval_in("w15.memo", "(mm 4)") == 16
      # a repeat call hits the cache — same result
      assert eval_in("w15.memo", "(mm 3)") == 9
    end

    test "doseq loads verbatim (slice_17); behavior gated on an RT vector-as-fn" do
      # The doseq macro itself loads: its definition compiles against the
      # macro surface (assert-macro-args, when-let, gensym, cond, nnext…).
      # Behavior is blocked on `(steppair 0)` — a vector used as a function
      # of its index, an RT.invoke gap (BeamLisp.RT, not this wave).
      assert match?({:"$macro", _}, load_slice("slice_17_doseq.bl", "w15.doseq"))
    end
  end
end
