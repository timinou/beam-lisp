# scripts/record_cassette.exs — record one real provider turn to a cassette.
#
#   PROVIDER=glm mix run scripts/record_cassette.exs content-turn
#   PROVIDER=glm mix run scripts/record_cassette.exs tool-call --tools
#   PROVIDER=glm mix run scripts/record_cassette.exs stream-content --stream
#   PROVIDER=glm mix run scripts/record_cassette.exs stream-tool-call --stream --tools
#
# ── why recording is a script and never a test ──────────────────────────────
#
# A test that records on a cache miss silently reaches the network, and then
# fails in CI for reasons nobody can reproduce — the key is missing, or the
# quota is gone, or the model answered differently this time. So the split is
# absolute: this script RECORDS (needs a key, run by a human, deliberately),
# and everything else REPLAYS.
#
# ── why the request is recorded too ─────────────────────────────────────────
#
# The defect that motivated cassettes was not a decoding bug. The served page
# offered the model NO tools — `from-env` returns a cfg with no `:tools` key,
# so `request-body` omitted the array entirely and the model was structurally
# incapable of proposing anything. Every test passed, because every test only
# ever looked at responses.
#
# A cassette carries the exact bytes we SENT, so a test can assert the tools
# array is there. That is the half that had no coverage.
#
# ── the fixtures this records, and why these four ───────────────────────────
#
#   content-turn        the ordinary answer
#   tool-call           the model asks for `run` — the shape the loop runs on
#   stream-content      the same answer, as SSE deltas
#   stream-tool-call    a tool call SPLIT ACROSS FRAMES — the one that was
#                       impossible to handle before W2, because
#                       `parse-sse-deltas` kept only `content` fields
#
# The last one is the important one: it is the exact turn the served page needs
# to be able to grow itself, and no hand-written fixture would be trustworthy
# for it, because the frame boundaries are the provider's choice.

alias BeamLisp.Spell

defmodule RecordCassette do
  @tool_prompt """
  Add a view named "clock" using the run tool.

  It needs:
    - one template named "clockface" with html "<div class='clock'>{@m.text}</div>"
    - one style rule for ".clock" with {"font-size": "0.75rem", "opacity": "0.6"}
    - one bind on ".log" with each {"binding": "messages", "as": "m", "template": "clockface"}

  Bind to ".log", which the page already renders.

  Call the tool. Do not describe it.
  """

  @content_prompt "In one sentence: what is a contract in this system?"

  def run([name | flags]) do
    Spell.Credentials.load()
    :inets.start()
    :ssl.start()
    Spell.init!(["spell.app"])

    stream? = "--stream" in flags
    tools? = "--tools" in flags

    cfg = base_cfg(tools?)

    unless bl("spell.provider", "configured?", [cfg]) do
      abort("""
      no API key for PROVIDER=#{System.get_env("PROVIDER") || "kimi"}.

      Recording is the one thing here that needs a live provider. Export a key
      (or put it in .env) and re-run. Everything else replays what this writes.
      """)
    end

    messages = [%{role: "user", content: if(tools?, do: @tool_prompt, else: @content_prompt)}]

    IO.puts("recording #{name}: provider=#{cfg[:model]} stream=#{stream?} tools=#{tools?}")

    request = bl("spell.provider", "request-body", [cfg, to_bl(messages), stream?])
    response = bl("spell.provider", "send-request", [cfg, to_bl(messages), stream?])

    case Map.get(response, :error) do
      nil -> :ok
      reason -> abort("the provider call failed: #{inspect(reason)}")
    end

    status = Map.get(response, :status)
    body = Map.get(response, :body)

    if status != 200 do
      abort("HTTP #{status}: #{String.slice(body, 0, 400)}")
    end

    # What was recorded is REPORTED, not assumed. A cassette named
    # `tool-call` that recorded a prose answer (because the model declined to
    # call the tool) would replay as a turn the loop cannot act on, and the
    # test built on it would fail somewhere far away.
    describe(body, stream?, tools?)

    path =
      bl("spell.cassette", "write!", [
        to_bl(%{
          name: name,
          provider: System.get_env("PROVIDER") || "kimi",
          stream: stream?,
          request: to_string(request),
          body: body,
          status: status
        })
      ])

    IO.puts("wrote #{path} (#{File.stat!(path).size} B)")
  end

  def run(_) do
    abort("usage: mix run scripts/record_cassette.exs NAME [--stream] [--tools]")
  end

  # The cfg to record with: the configured provider, plus the `run` tool
  # declaration when asked. Taken from `Spell.Loop.run_tool/0` rather than
  # restated, so a cassette records the tool the loop actually offers.
  defp base_cfg(tools?) do
    cfg = bl("spell.provider", "from-env", [])
    if tools?, do: Map.put(cfg, :tools, to_bl([Spell.Loop.run_tool()])), else: cfg
  end

  defp describe(body, true, _tools?) do
    frames = body |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "data: "))
    calls = bl("spell.provider", "stream-tool-calls", [body])
    deltas = bl("spell.provider", "parse-sse-deltas", [body])

    IO.puts("  #{frames} SSE frame(s)")
    report_calls(calls)
    IO.puts("  #{length(to_list(deltas))} content delta(s)")
  end

  defp describe(body, false, _tools?) do
    turn = bl("spell.provider", "extract-turn", [body])
    IO.puts("  kind: #{inspect(Map.get(turn, :kind))}")
    report_calls(Map.get(turn, :"tool-calls", []))
  end

  defp report_calls(calls) do
    case to_list(calls) do
      [] ->
        IO.puts("  no tool calls")

      list ->
        for c <- list do
          args = to_string(Map.get(c, :arguments, ""))
          IO.puts("  tool call: #{Map.get(c, :name)} (#{byte_size(args)} B of arguments)")

          case JSON.decode(args) do
            {:ok, decoded} -> IO.puts("    arguments parse: ok, keys #{inspect(Map.keys(decoded))}")
            {:error, why} -> IO.puts("    arguments DO NOT PARSE: #{inspect(why)}")
          end
        end
    end
  end

  defp bl(ns, name, args), do: apply(BeamLisp.Env.fetch!(ns, name), args)
  defp to_bl(value), do: Spell.Data.to_bl(value, :as_written)
  defp to_list(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp to_list(other) when is_list(other), do: other
  defp to_list(_), do: []

  defp abort(message) do
    IO.puts(:stderr, "\n" <> message <> "\n")
    System.halt(1)
  end
end

RecordCassette.run(System.argv())
