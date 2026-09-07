defmodule BeamLisp.DirectFormsTest do
  use ExUnit.Case, async: false

  defp eval(ns, source) do
    BeamLisp.init()
    BeamLisp.Compiler.eval_string("(ns #{ns})\n" <> source, BeamLisp.Compiler.new_env(ns))
  end

  test "explicit Elixir prefixes resolve to the same host module" do
    assert eval("qualifiedhost", "(Elixir.String/upcase \"hello\")") == "HELLO"
    assert eval("qualifiedhost", "(let [f Elixir.String/upcase] (f \"hello\"))") == "HELLO"
    child = BeamLisp.Env.fork(:global, caps: [])
    try do
      assert_raise BeamLisp.CompileError, fn ->
        BeamLisp.Env.with_env(child, fn -> eval("qualifiedhost", "(Elixir.String/upcase \"denied\")") end)
      end
    after
      BeamLisp.Env.destroy(child)
    end
  end

  test "defserver preserves guarded callback dispatch" do
    mod =
      eval("directserverinvariant", """
      (defserver bounded
        (invariant [state] (>= state 0))
        (init [x] (ok x))
        (handle-call :get [_from state] (reply state state)))
      bounded
      """)

    assert mod.__invariant__(0)
    refute mod.__invariant__(-1)

    assert eval("directserverguard", """
           (defserver bank
             (init [x] (ok x))
             (handle-call [:take n] :when (pos? n) [_from state]
               (reply :accepted (- state n)))
             (handle-call [:take _n] [_from state] (reply :rejected state))
             (handle-call :balance [_from state] (reply state state)))
           (let [p (start-link bank 10)
                 a (call p [:take 3])
                 b (call p [:take -1])
                 c (call p :balance)]
             (stop p)
             (list a b c))
           """) == [:accepted, :rejected, 7]
  end

  test "direct definitions store rich metadata as plain data" do
    ns = "directmetadata"

    assert eval(ns, """
           (def ^{:doc "author" :tag String :custom {:nested '([x])}} value "explicit" 1)
           (defn- ^{:private false :arglists '([x]) :tag Number :custom [:fn]} function [x] x)
           (defmacro ^{:arglists '([form]) :tag MacroTag :custom [:macro]} identity-form [form] form)
           (defmacro define-rich [name]
             `(defn ~(vary-meta name assoc
                       :arglists (list 'quote (list '[x]))
                       :tag 'MacroProvided
                       :custom {:origin :macro})
                [x] x))
           (define-rich generated)
           (list value (function 2) (identity-form 3) (generated 4))
           """) == [1, 2, 3, 4]

    assert {:ok, value_meta} = BeamLisp.Env.meta(ns, "value")
    assert value_meta.doc == "explicit"
    assert value_meta.tag == {:symbol, "String"}
    # Only an outer metadata quote is stripped; a nested quote stays data.
    assert value_meta.custom == %{
             nested: [{:symbol, "quote"}, [%BeamLisp.Vector{items: {{:symbol, "x"}}}]]
           }
    refute Map.has_key?(value_meta, :line)
    refute Map.has_key?(value_meta, :col)
    refute Map.has_key?(value_meta, :file)

    assert {:ok, function_meta} = BeamLisp.Env.meta(ns, "function")
    assert function_meta.private
    assert function_meta.tag == {:symbol, "Number"}
    assert function_meta.custom == %BeamLisp.Vector{items: {:fn}}
    assert [%BeamLisp.Vector{items: {{:symbol, "x"}}}] = function_meta.arglists

    assert {:ok, macro_meta} = BeamLisp.Env.meta(ns, "identity-form")
    assert macro_meta.tag == {:symbol, "MacroTag"}
    assert macro_meta.custom == %BeamLisp.Vector{items: {:macro}}

    assert {:ok, generated_meta} = BeamLisp.Env.meta(ns, "generated")
    assert generated_meta.tag == {:symbol, "MacroProvided"}
    assert generated_meta.custom == %{origin: :macro}
    assert [%BeamLisp.Vector{items: {{:symbol, "x"}}}] = generated_meta.arglists

    source = File.read!("priv/boot/compiler.bl")
    refute source =~ "(a/normalise meta)"
    refute source =~ "Macro/escape"
  end

  test "defserver reload replaces callbacks and preserves client defaults" do
    assert eval("directserverreload", """
           (defserver counter
             (init [x] (ok x))
             (handle-call :step [_from state] (reply (+ state 1) (+ state 1))))
           (def old counter)
           (defserver counter
             (init [x] (ok x))
             (handle-call :step [_from state] (reply (+ state 2) (+ state 2))))
           (let [p (start counter 1)
                 value (call p :step)]
             (stop p)
             (list (= old counter) value))
           """) == [true, 3]
  end
end
