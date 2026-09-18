defmodule BeamLisp.NifTraceTest do
  use ExUnit.Case, async: false

  # The recorder answers one question: which call was in flight when the VM
  # died. These tests answer it against a copy of the real thing — the LazyMemo
  # NIFs the build exercises by the thousand — so the recorder is proven on the
  # path it exists for, not on a toy module.

  setup do
    path = Path.join(System.tmp_dir!(), "nif-trace-#{System.unique_integer([:positive])}.log")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  defp lines(path) do
    case File.read(path) do
      {:ok, text} -> text |> String.split("\n", trim: true)
      _ -> []
    end
  end

  test "records the NIF-boundary calls the memo makes", %{path: path} do
    rec = BeamLisp.NifTrace.start(path)

    cell = BeamLisp.LazyMemo.create(123)
    :ok = BeamLisp.LazyMemo.exchange(cell, 123, 456)
    _ = BeamLisp.LazyMemo.cursor([1, 2, 3])
    :ok = BeamLisp.NifTrace.stop(rec)

    recorded = lines(path)
    names = Enum.map(recorded, fn line -> line |> String.split(" ") |> Enum.at(1) end)

    # The NIFs themselves are not traceable — `load_nif` replaces the Erlang
    # body, so the VM generates no message for them. What is recorded is the
    # Erlang funnel that called them, which is what locates the work.
    assert "create/1" in names,
           "expected the cell creation to be recorded, got: #{inspect(names)}"

    assert "exchange/4" in names,
           "expected the exchange to be recorded, got: #{inspect(names)}"

    assert "cursor/1" in names,
           "expected the cursor creation to be recorded, got: #{inspect(names)}"
  end

  test "records nothing once stopped", %{path: path} do
    rec = BeamLisp.NifTrace.start(path)
    _ = BeamLisp.LazyMemo.create(1)
    :ok = BeamLisp.NifTrace.stop(rec)

    before = length(lines(path))
    _ = BeamLisp.LazyMemo.create(2)
    assert length(lines(path)) == before
  end

  test "is inert when off: no file, no tracer" do
    assert BeamLisp.NifTrace.path() == nil
    assert BeamLisp.NifTrace.start_from_env() == :off
  end

  test "each line carries the call and the process that made it", %{path: path} do
    rec = BeamLisp.NifTrace.start(path)
    _ = BeamLisp.LazyMemo.create(7)
    :ok = BeamLisp.NifTrace.stop(rec)

    assert [line | _] = lines(path)
    assert line =~ "create/1"
    assert line =~ "BeamLisp.LazyMemo"
    assert line =~ "pid="
  end
end
