defmodule BeamLisp.AnfEmitTest do
  use ExUnit.Case, async: false

  alias BeamLisp.Emit

  test "ANF shims collapse guarded clauses and preserve distinct arities" do
    body_mod = BeamLisp.Ns.Body.AnfEmitFixture

    clause = fn fname, params, guard ->
      {:fixed, length(params), fname,
       %{
         op: :"defn-clause",
         fname: fname,
         params: Enum.map(params, &%{pop: :pvar, name: &1}),
         guard: guard,
         body: %{op: :lit, val: :unused},
         ann: %{}
       }, body_mod}
    end

    defs = [
      clause.(:classify, [:x], %{op: :lit, val: true}),
      clause.(:classify, [:y], nil),
      clause.(:classify, [:x, :y], nil)
    ]

    shims = Emit.shim_clauses(%{"classify" => defs})

    assert length(shims) == 2
    assert Enum.map(shims, &length(&1.params)) |> Enum.sort() == [1, 2]

    assert Enum.all?(shims, fn shim ->
             shim.op == :"defn-clause" and shim.guard == nil and
               shim.body.op == :remote and shim.body.mod == body_mod and
               shim.body.fun == :classify and length(shim.body.args) == length(shim.params)
           end)
  end

  test "generated live and disk consumers contain no quoted reverse bridge" do
    for path <- ["lib/beam_lisp/link.ex", "lib/beam_lisp/emit.ex", "lib/beam_lisp/aot.ex"] do
      source = File.read!(path)
      refute source =~ "quote do"
      refute source =~ "quote-node"
      refute source =~ "normalise"
      refute source =~ "Code.compile_quoted"
      refute source =~ ":elixir_compiler.quoted"
      refute source =~ "Module.create"
    end
  end

  test "canonical descriptor boundary validates body and neutral shim modules" do
    body_mod = BeamLisp.Ns.Body.DescriptorFixture
    clause = %{
      op: :"defn-clause", fname: :identity,
      params: [%{pop: :pvar, name: "x"}], guard: nil,
      body: %{op: :var, name: "x", ann: %{}}, ann: %{}
    }
    defs = %{"identity" => [{:fixed, 1, :identity, clause, body_mod}]}

    body = Emit.descriptor_for(body_mod, [clause])
    shim = Emit.descriptor_for(BeamLisp.Ns.DescriptorFixture, Emit.shim_clauses(defs))

    assert body.op == :module
    assert [%BeamLisp.Vector{items: {:identity, 1}}] = body.exports
    assert [%{op: :"defn-clause", guard: nil}] = shim.clauses
    assert {^body_mod, body_bytes} = Emit.compile_descriptor(body)
    assert is_binary(body_bytes)
  end

  test "AOT compiles guarded and multi-arity canonical ANF definitions" do
    output_dir = Path.join(System.tmp_dir!(), "beam_lisp_anf_emit_#{System.unique_integer([:positive])}")
    on_exit(fn ->
      for mod <- [BeamLisp.Ns.AnfEmitFixture, BeamLisp.Ns.Body.AnfEmitFixture] do
        :code.purge(mod)
        :code.delete(mod)
      end

      File.rm_rf!(output_dir)
    end)

    source = """
    (ns anf_emit_fixture)
    (defn classify
      ([n] :when (pos? n) :positive)
      ([n] :when (neg? n) :negative)
      ([_n] :zero)
      ([a b] (+ a b)))
    """

    emitted = BeamLisp.AOT.compile_source(source, output_dir: output_dir)
    emitted_modules = MapSet.new(emitted, &elem(&1, 0))

    assert BeamLisp.Ns.AnfEmitFixture in emitted_modules
    assert BeamLisp.Ns.Body.AnfEmitFixture in emitted_modules

    # Emission publishes body code before namespace shims. No manual load or
    # purge should be needed for the running compiler to use the new body.
    assert :ok == BeamLisp.Ns.AnfEmitFixture.__bl_init__()
    assert BeamLisp.Ns.AnfEmitFixture.classify(4) == :positive
    assert BeamLisp.Ns.AnfEmitFixture.classify(-4) == :negative
    assert BeamLisp.Ns.AnfEmitFixture.classify(0) == :zero
    assert BeamLisp.Ns.AnfEmitFixture.classify(2, 3) == 5
  end
end
