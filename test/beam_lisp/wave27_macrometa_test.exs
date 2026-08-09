defmodule BeamLisp.Wave27MacroMetaTest do
  @moduledoc """
  Two gaps found by loading Specter's navigator macro stack, both of which
  bite ordinary macro-writing code long before anyone reaches Specter.

  ## Metadata a macro attached, rather than metadata someone wrote

  `var_meta_ast/4` compiled each metadata value as a reader FORM, which is
  what it is when an author writes `^{:arglists '([x])}` in source. But a
  macro that builds metadata itself --

      (vary-meta name assoc :arglists '([]))

  -- stores *datum*: by the time the macro runs, the quoted form has already
  been evaluated into data, so the value is a bare Elixir list. `do_compile/2`
  has no clause for bare data, so this crashed with a raw
  `FunctionClauseError` naming neither the var nor the offending key.

  The fix routes such values through `data_to_form/1`, the datum-to-form
  bridge syntax-quote already uses crossing back the other way. The two paths
  converge on one mechanism instead of each growing its own clauses.

  This gated four Specter slices (15, 23, 24, 26) *simultaneously* -- all of
  them expand through `defnav`/`defrichnav`, which attach `:arglists` exactly
  this way.

  ## `declare`

  Simply absent. A file cannot forward-reference a function defined later,
  which mutually recursive definitions and navigator libraries both need.
  """
  use ExUnit.Case, async: false

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

  describe "metadata attached by a macro" do
    test "a macro may attach a quoted list as metadata" do
      # The exact shape `defnav` uses. Before the fix this raised a
      # FunctionClauseError from deep inside the compiler.
      # This is Specter's own spelling, from slice 05's `defnav`:
      #   (vary-meta name assoc :arglists (list 'quote (list params)))
      # -- the value is built with `list`, so it reaches the compiler as data,
      # not as a reader form.
      eval("""
      (defmacro w27-defthing [nm params]
        (let [tagged (vary-meta nm assoc :arglists (list 'quote (list params)))]
          `(defn ~tagged [] :made)))
      """)

      eval("(w27-defthing w27-widget [x])")
      assert eval("(w27-widget)") == :made
      {:ok, m} = BeamLisp.Env.meta("user", "w27-widget")
      assert Map.has_key?(m, :arglists)
    end

    test "the attached metadata is readable, not merely survivable" do
      # Compiling without crashing is not enough -- the value has to arrive
      # intact, or the macro silently lost what it attached.
      eval("""
      (defmacro w27-tagged [nm]
        `(defn ~(vary-meta nm assoc :kind :navigator) [] 1))
      """)

      eval("(w27-tagged w27-nav)")
      assert {:ok, %{kind: :navigator}} = BeamLisp.Env.meta("user", "w27-nav")
    end

    test "metadata written in source still works unchanged" do
      # The other half of the same function. A fix that rerouted the datum
      # path but broke the form path would trade one bug for another.
      eval("(defn ^{:arglists '([x])} w27-src [] 1)")
      assert eval("(w27-src)") == 1

      eval("(defn ^{:doc \"a docstring\"} w27-doc [] 2)")
      assert {:ok, %{doc: "a docstring"}} = BeamLisp.Env.meta("user", "w27-doc")

      # A bare symbol value stays the symbol datum Clojure stores; it must
      # NOT be compiled, which would try to resolve it as a var.
      eval("(defn ^{:tag String} w27-tag [] 3)")
      assert eval("(w27-tag)") == 3
    end
  end

  describe "declare" do
    test "a function may reference one defined later in the file" do
      assert eval("""
             (do
               (declare w27-later)
               (defn w27-early [] (w27-later))
               (defn w27-later [] 42)
               (w27-early))
             """) == 42
    end

    test "declare takes several names" do
      assert eval("""
             (do
               (declare w27-a w27-b)
               (defn w27-uses [] (+ (w27-a) (w27-b)))
               (defn w27-a [] 1)
               (defn w27-b [] 2)
               (w27-uses))
             """) == 3
    end

    test "mutual recursion, which is the reason declare exists" do
      assert eval("""
             (do
               (declare w27-odd?)
               (defn w27-even? [n] (if (= n 0) true (w27-odd? (- n 1))))
               (defn w27-odd? [n] (if (= n 0) false (w27-even? (- n 1))))
               [(w27-even? 10) (w27-odd? 7)])
             """) == BeamLisp.Vector.new([true, true])
    end
  end
end
