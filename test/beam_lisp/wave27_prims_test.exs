defmodule BeamLisp.Wave27PrimsTest do
  # wave 27: the ten prims that gate the Specter slices — type,
  # instance?, symbol, sequence, keys, vals, vec, subs, dissoc,
  # unreduced. The self-hosted suite in test/bl/prelude_test.bl covers
  # the behavioural edges; this file holds the Elixir-side assertions:
  # the exact tuple shape `symbol` must match, that the collection fns
  # keep raising on reference types (wave-1 consistency), and that `vec`
  # realizes a lazy seq.
  import BeamLisp.Test, only: [realize: 1]

  use ExUnit.Case, async: false

  defp eval(source), do: BeamLisp.eval(source)

  # the ref fns raise ArgumentError (RT) while dissoc raises the beam-lisp
  # ExInfo it throws — assert the outcome (it raises), not the flavour.
  defp raises?(fun) do
    try do
      fun.()
      false
    rescue
      _ -> true
    end
  end

  test "symbol builds the exact reader tuple {:symbol, name}" do
    assert eval("(symbol \"x\")") == {:symbol, "x"}
    assert eval("(symbol \"foo\" \"bar\")") == {:symbol, "foo/bar"}
    assert eval("(symbol nil \"x\")") == {:symbol, "x"}
    assert eval("(symbol :kw)") == {:symbol, "kw"}
  end

  test "type returns the type_of vocabulary for builtins and the module for a record" do
    assert eval("(type 5)") == :integer
    assert eval("(type 1.5)") == :float
    assert eval("(type \"s\")") == :binary
    assert eval("(type [1])") == :vector
    assert eval("(type {:a 1})") == :map
    assert eval("(type nil)") == :nil

    eval("(defrecord W27ET [x y])")
    mod = eval("(type (->W27ET 1 2))")
    # the module is a beam-lisp record module, and the Specter shape works
    assert is_atom(mod)
    # "#" <> "{...}" avoids Elixir string interpolation of the set literal
    assert eval("(contains? " <> "#" <> "{W27ET} (type (->W27ET 1 2)))") == true
  end

  test "instance? checks type identity for builtins and user types" do
    assert eval("(instance? :vector [1 2])") == true
    assert eval("(instance? :integer 5)") == true
    assert eval("(instance? :integer 5.0)") == false
    assert eval("(instance? :map [1 2])") == false

    eval("(defrecord W27EI [x y])")
    assert eval("(instance? W27EI (->W27EI 1 2))") == true
    assert eval("(instance? W27EI {:a 1})") == false
  end

  test "vec realizes a lazy seq and nil-puns to []" do
    assert eval("(vec nil)") == BeamLisp.Vector.new()
    assert eval("(vec [1 2 3])") == BeamLisp.Vector.new([1, 2, 3])
    # (range 3) is a lazy seq; vec must force it, not return a LazySeq
    v = eval("(vec (range 3))")
    assert %BeamLisp.Vector{} = v
    assert v == BeamLisp.Vector.new([0, 1, 2])
  end

  test "collection fns still RAISE on reference types (wave-1 consistency)" do
    for expr <- ["(keys (atom 1))", "(vals (atom 1))", "(vec (atom 1))",
                 "(sequence (atom 1))", "(dissoc (atom 1) :k)", "(dissoc (atom 1) :value)"] do
      assert raises?(fn -> eval(expr) end)
    end
  end

  test "sequence returns () on empty and an actual seq otherwise" do
    assert realize(eval("(sequence nil)")) == []
    assert realize(eval("(sequence [])")) == []
    assert eval("(seq? (sequence [1 2 3]))") == true
    assert realize(eval("(sequence [1 2 3])")) == [1, 2, 3]
    assert realize(eval("(sequence (take 2) [1 2 3 4])")) == [1, 2]
    assert realize(eval("(sequence (take 0) [1 2 3 4])")) == []
  end

  test "keys and vals round-trip the map and agree with seq" do
    ks = realize(eval("(keys {:a 1 :b 2})"))
    vs = realize(eval("(vals {:a 1 :b 2})"))
    assert Enum.sort(ks) == [:a, :b]
    assert Enum.sort(vs) == [1, 2]
    assert Enum.zip(ks, vs) |> Map.new() |> Map.keys() |> Enum.sort() == [:a, :b]
    # nil punning
    assert eval("(keys nil)") == nil
    assert eval("(vals nil)") == nil
    assert eval("(keys {})") == nil
  end

  test "subs is char-based and raises out of range" do
    assert eval("(subs \"hello\" 1)") == "ello"
    assert eval("(subs \"hello\" 1 3)") == "el"
    assert eval("(subs \"héllo\" 1 2)") == "é"
    assert eval("(subs \"hello\" 5)") == ""
    assert_raise BeamLisp.ExInfo, fn -> eval("(subs \"hello\" 9)") end
  end

  test "unreduced unwraps a Reduced and passes values through" do
    assert eval("(unreduced (reduced 42))") == 42
    assert eval("(unreduced 42)") == 42
    assert eval("(unreduced nil)") == nil
  end

  test "dissoc on a record's declared field yields a plain map" do
    eval("(defrecord W27ED [x y])")
    r = eval("(->W27ED 1 2)")
    d = eval("(dissoc (->W27ED 1 2) :x)")
    # a real map, not a half-broken struct
    assert d == %{y: 2}
    refute BeamLisp.Record.record?(d)
    # dissoc'ing a non-declared key keeps it a record
    d2 = eval("(dissoc (->W27ED 1 2) :zz)")
    assert BeamLisp.Record.record?(d2)
    refute is_nil(r)
    assert eval("(dissoc nil :k)") == nil
  end
end
