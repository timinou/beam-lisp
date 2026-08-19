defmodule BeamLisp.Spell.ProviderTest do
  @moduledoc """
  The lean provider: the SSE parser (pure, so the fake can exercise the live
  path), the providers table, and the .env sourcing rule.
  """
  use ExUnit.Case, async: false

  alias BeamLisp.Spell.Provider

  describe "parse_frame/2" do
    test "a content delta is an event" do
      {events, rest} = Provider.parse_frame("", ~s(data: {"choices":[{"delta":{"content":"hi"}}]}) <> "\n\n")
      assert events == [{:delta, "hi"}]
      assert rest == ""
    end

    test "an event split across frames waits for its boundary" do
      {e1, rest} = Provider.parse_frame("", ~s(data: {"choices":[{"delta":{"content":"he))
      assert e1 == []

      {e2, ""} = Provider.parse_frame(rest, ~s(llo"}}]}) <> "\n\n")
      assert e2 == [{:delta, "hello"}]
    end

    test "tool-call fragments arrive with index, name once, arguments in chunks" do
      frames =
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"run","arguments":"{\\"sou"}}]}}]}) <>
          "\n\n" <>
          ~s(data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"rce\\"}"}}]}}]}) <>
          "\n\n" <>
          ~s(data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}) <> "\n\n" <>
          "data: [DONE]\n\n"

      {events, ""} = Provider.parse_frame("", frames)

      assert events == [
               {:tool_delta, 0, "run", "{\"sou"},
               {:tool_delta, 0, nil, "rce\"}"},
               {:finish, "tool_calls"},
               :done
             ]
    end

    test "empty content, role frames and usage trailers produce no events" do
      {events, _} =
        Provider.parse_frame(
          "",
          ~s(data: {"choices":[{"delta":{"role":"assistant","content":""}}]}) <>
            "\n\n" <> ~s(data: {"usage":{"total_tokens":3}}) <> "\n\n"
        )

      # a content-less delta is NOTHING (no event); a non-choices frame is :ignore
      assert events == [:ignore]
    end

    test "reasoning_content is not surfaced as an answer" do
      {events, _} =
        Provider.parse_frame("", ~s(data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}) <> "\n\n")

      assert events == []
    end
  end

  describe "from_env/0" do
    setup do
      old = System.get_env("PROVIDER")
      on_exit(fn -> if old, do: System.put_env("PROVIDER", old), else: System.delete_env("PROVIDER") end)
      :ok
    end

    test "PROVIDER selects the row; unknown falls back to kimi" do
      System.put_env("PROVIDER", "deepseek")
      assert Provider.from_env().model =~ "deepseek"

      System.put_env("PROVIDER", "no-such-provider")
      assert Provider.from_env().base_url =~ "kimi"
    end

    test "the fake row is configured and carries canned frames" do
      System.put_env("PROVIDER", "fake")
      cfg = Provider.from_env()
      assert Provider.configured?(cfg)
      assert {:fake, payloads} = cfg.transport
      assert length(payloads) == 3
    end

    test "a missing key is a clear no, not a 401" do
      System.put_env("PROVIDER", "glm")
      System.delete_env("GLM_API_KEY")
      refute Provider.configured?(Provider.from_env())
    end
  end

  describe "the fake through the real path" do
    test "stream_start plays the frames through the caller's mailbox" do
      System.put_env("PROVIDER", "fake")
      cfg = Provider.from_env()

      {:ok, ref} = Provider.stream_start(cfg, [])

      assert_receive {:http, {^ref, :stream, body}}
      assert_receive {:http, {^ref, :stream_end, _}}

      {events, ""} = Provider.parse_frame("", body)
      assert {:delta, "fake"} in events
      assert {:delta, " answer"} in events
      assert {:finish, "stop"} in events
      assert :done in events
    after
      System.delete_env("PROVIDER")
    end
  end
end
