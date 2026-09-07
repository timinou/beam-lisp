defmodule BeamLisp.CanonicalRecordInteropTest do
  use ExUnit.Case, async: false

  test "generated records support Elixir literals and struct patterns" do
    BeamLisp.init()
    record = BeamLisp.Record.define("canonicalinterop", "Point", ["x", "y"])
    consumer = Module.concat(__MODULE__, "Consumer#{System.unique_integer([:positive])}")
    Code.compile_string("""
    defmodule #{inspect(consumer)} do
      def create, do: %#{inspect(record)}{x: 3}
      def read(%#{inspect(record)}{x: value}), do: value
    end
    """)
    assert consumer.create() == %{__struct__: record, x: 3, y: nil}
    assert consumer.read(consumer.create()) == 3
    old_hash = record.__info__(:exports_md5)
    assert ^record = BeamLisp.Record.define("canonicalinterop", "Point", ["x", "z"])
    refute record.__info__(:exports_md5) == old_hash
    next = Module.concat(consumer, "Next")
    Code.compile_string("defmodule #{inspect(next)} do def create, do: %#{inspect(record)}{z: 7} end")
    assert next.create() == %{__struct__: record, x: nil, z: 7}
    assert_raise ArgumentError, ~r/cannot set :__struct__/, fn ->
      BeamLisp.Record.define("canonicalinterop", "Point", ["__struct__"])
    end
    assert record.__struct__() == %{__struct__: record, x: nil, z: nil}
  end
end
