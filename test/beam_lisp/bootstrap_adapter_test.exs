defmodule BeamLisp.CanonicalBoundaryTest do
  use ExUnit.Case, async: false
  alias BeamLisp.Emit

  setup do
    BeamLisp.init()
    :ok
  end

  test "canonical module assembly executes body semantics" do
    mod = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")
    descriptor = Emit.descriptor_for(mod, [Emit.function_clause(:answer, Emit.lit(42))])
    {^mod, binary} = Emit.compile_descriptor(descriptor)
    Emit.load_binary!({mod, binary})
    assert apply(mod, :answer, []) == 42
  end

  test "quoted clauses are refused rather than sent to another compiler" do
    quoted = {:def, [], [{:answer, [], []}, [do: 42]]}
    assert_raise BeamLisp.ExInfo, fn ->
      Emit.descriptor(:bad_quoted_clause, [quoted], [{:answer, 0}])
    end
  end
end
