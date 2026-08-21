defmodule BeamLisp.Spell.TurnTest do
  @moduledoc """
  The page's turn, end to end and offline: `(ask! text)` → loop → provider
  (fake) → streamed messages back to the caller, and — when the model calls
  the tool — through the LADDER, with the verdict arriving as `[:defined …]`.
  """
  use ExUnit.Case, async: false

  alias BeamLisp.Spell.Loop

  # One streamed tool call: arguments JSON-encoded INSIDE the SSE payload,
  # exactly the OpenAI streaming shape (name once, arguments in chunks).
  defp tool_call_scenario(source, rationale) do
    args = JSON.encode!(%{source: source, rationale: rationale})
    half = div(String.length(args), 2)
    {a, b} = String.split_at(args, half)

    [
      ~s({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"run","arguments":#{JSON.encode!(a)}}}]}}]}),
      ~s({"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":#{JSON.encode!(b)}}}]}}]}),
      ~s({"choices":[{"delta":{},"finish_reason":"tool_calls"}]})
    ]
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "spell-turn-#{System.unique_integer([:positive])}")
    Application.put_env(:beam_lisp, :spell_state_dir, dir)

    old_provider = System.get_env("PROVIDER")
    old_scenario = System.get_env("SPELL_FAKE_SCENARIO")
    System.put_env("PROVIDER", "fake")

    on_exit(fn ->
      # `whereis`-then-`stop` is a TOCTOU race, and stopping a dying
      # process EXITS rather than returning (BUG-015).
      if pid = Process.whereis(Loop) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
      restore("PROVIDER", old_provider)
      restore("SPELL_FAKE_SCENARIO", old_scenario)
      Application.delete_env(:beam_lisp, :spell_state_dir)
      File.rm_rf(dir)
    end)

    :ok
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)

  defp collect_turn(id, acc \\ []) do
    receive do
      {:delta, ^id, chunk} -> collect_turn(id, [{:delta, chunk} | acc])
      {:defined, ^id, text} -> collect_turn(id, [{:defined, text} | acc])
      {:done, ^id} -> Enum.reverse([:done | acc])
      {:failed, ^id, why} -> Enum.reverse([{:failed, why} | acc])
    after
      30_000 -> Enum.reverse([:timeout | acc])
    end
  end

  test "a text turn streams deltas, records both sides, and ends" do
    {:ok, _pid} = Loop.start_link(publish: false, persist: false)

    id = Loop.ask_async(Loop, "say hi", self())
    events = collect_turn(id)

    assert List.last(events) == :done

    text =
      events
      |> Enum.filter(fn e -> match?({:delta, _}, e) end)
      |> Enum.map(fn {:delta, c} -> c end)
      |> Enum.join()

    assert text == "fake answer"

    messages = Loop.transcript_messages(Loop)
    assert Enum.any?(messages, fn m -> m["role"] == "user" and m["text"] == "say hi" end)
    assert Enum.any?(messages, fn m -> m["role"] == "model" and m["text"] == "fake answer" end)
  end

  test "a tool turn walks the ladder: the verdict is [:defined …], the machine grew" do
    System.put_env(
      "SPELL_FAKE_SCENARIO",
      JSON.encode!(tool_call_scenario("(def turn-var 41)", "the fake proposed it"))
    )

    {:ok, _pid} = Loop.start_link(publish: false, persist: false)

    id = Loop.ask_async(Loop, "define turn-var", self())
    events = collect_turn(id)

    assert List.last(events) == :done
    assert {:defined, text} = Enum.find(events, fn e -> match?({:defined, _}, e) end)
    assert text =~ "✓"
    assert text =~ "turn-var"

    # the ladder RAN: the var exists in the image
    assert {:ok, 41} = BeamLisp.Env.fetch("spell.vars", "turn-var")
  end

  test "a refused proposal arrives as [:defined …] with ✗ and the rung, and the budget ends it" do
    System.put_env(
      "SPELL_FAKE_SCENARIO",
      JSON.encode!(tool_call_scenario("(defmacro sneaky [x] x)", "no"))
    )

    {:ok, _pid} = Loop.start_link(publish: false, persist: false)

    id = Loop.ask_async(Loop, "try a macro", self())
    events = collect_turn(id)

    assert List.last(events) == :done

    defined = for {:defined, text} <- events, do: text
    assert Enum.any?(defined, fn t -> t =~ "✗" and t =~ "schema" end)
    assert List.last(defined) =~ "no definition accepted after 3 attempts"

    # and the machine did NOT grow
    assert :error = BeamLisp.Env.fetch("spell.vars", "sneaky")
  end
end
