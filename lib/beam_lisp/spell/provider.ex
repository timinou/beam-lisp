defmodule BeamLisp.Spell.Provider do
  @moduledoc """
  The model call: one OpenAI-compatible streaming client.

  The chat IS the product — the page's `(ask! text)` must reach a real model,
  in-process, without the operator wiring an external client. This module is
  the lean reincarnation of the provider half of the stack W5 deleted: the
  cassette recorder/replayer and the credential database are NOT back (they
  served the demo and a three-source key hunt), what is back is the one thing
  that was actually load-bearing — streaming chat completions with tool calls.

  ## Shape

    * `from_env/0` — `PROVIDER` selects a row from `providers/0` (kimi,
      deepseek, glm; each overridable by `<NAME>_BASE_URL` / `<NAME>_MODEL`),
      keys from `<NAME>_API_KEY`. A repo-root `.env` is sourced for UNSET vars
      first, so `PROVIDER=kimi mix run …` works with the keys where they live.
    * `stream_start/2` — begins a streamed completion; the CALLER's process is
      the httpc receiver, so no second process exists to leak or to orphan the
      turn. `{:ok, ref}` and the frames arrive as `{:http, {ref, …}}`.
    * `parse_frame/2` — the SSE decoding, pure: buffer + binary in, events +
      rest out. The turn loop (`Spell.Loop`) owns the protocol to the page;
      this module owns bytes → events.

  ## The fake

  `transport: {:fake, [sse_data_payload, …]}` in the cfg plays those SSE
  payloads through `stream_start` as synthetic httpc frames — so the offline
  path exercises the SAME parser a live turn runs. That equivalence is the
  point; the old fake imitated the message protocol and every parser bug was
  invisible to it.
  """


  @doc """
  One provider is a map of `%{base_url, model, key}` — switching models is
  DATA, not a code path, because one of them WILL be walled when you need it
  (a quota 403 looks exactly like a broken integration unless switching is one
  variable).
  """
  def providers do
    %{
      "kimi" => %{
        base_url: System.get_env("KIMI_BASE_URL") || "https://api.kimi.com/coding/v1",
        model: System.get_env("KIMI_MODEL") || "k3-256k",
        key: System.get_env("KIMI_API_KEY") || ""
      },
      "deepseek" => %{
        base_url: System.get_env("DEEPSEEK_BASE_URL") || "https://api.deepseek.com",
        model: System.get_env("DEEPSEEK_MODEL") || "deepseek-chat",
        key: System.get_env("DEEPSEEK_API_KEY") || ""
      },
      "glm" => %{
        base_url: System.get_env("GLM_BASE_URL") || "https://api.z.ai/api/coding/paas/v4",
        model: System.get_env("GLM_MODEL") || "glm-5.3",
        key: System.get_env("GLM_API_KEY") || ""
      },
      # Offline turns, for tests and checks: the SAME stream_start/parser path
      # as a live provider, over synthetic frames. `SPELL_FAKE_SCENARIO`
      # (a JSON array of SSE data payloads) replaces the canned answer when a
      # test needs the tool-call path rather than plain text.
      "fake" => %{
        base_url: "fake",
        model: "fake",
        key: "fake",
        transport: {:fake, fake_payloads()}
      }
    }
  end

  defp fake_payloads do
    case System.get_env("SPELL_FAKE_SCENARIO") do
      nil ->
        [
          ~s({"choices":[{"delta":{"content":"fake"}}]}),
          ~s({"choices":[{"delta":{"content":" answer"}}]}),
          ~s({"choices":[{"delta":{},"finish_reason":"stop"}]})
        ]

      json ->
        JSON.decode!(json)
    end
  end

  @doc """
  The provider config selected by `PROVIDER` (default kimi), with the repo's
  `.env` sourced for variables the real environment does not set.

  An unknown `PROVIDER` falls back to kimi rather than raising: a name the
  table does not know is not necessarily a mistake (tests add rows), and the
  failure that matters — no key — is reported by `configured?/1` regardless.
  """
  def from_env do
    load_dotenv()
    name = System.get_env("PROVIDER")
    Map.get(providers(), name) || Map.fetch!(providers(), "kimi")
  end

  @doc "Is there a key to call with? A missing credential is a clear message, not a 401."
  def configured?(%{transport: {:fake, _}}), do: true
  def configured?(%{key: key}), do: key not in [nil, ""]

  # Real environment first, `.env` second — and only for variables the real
  # environment did NOT set, so `PROVIDER=deepseek` on the command line is not
  # silently replaced by the file's `PROVIDER=kimi` (the quietest failure the
  # old three-source credential hunt produced).
  defp load_dotenv do
    path = Path.join(File.cwd!(), ".env")

    if File.regular?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.each(fn line ->
        case String.split(String.trim(line), "=", parts: 2) do
          [key, value] when key != "" ->
            unless String.starts_with?(key, "#") or System.get_env(key) do
              System.put_env(key, String.trim(value, ~s("')))
            end

          _ ->
            :ok
        end
      end)
    end

    :ok
  end

  # ── streaming ─────────────────────────────────────────────────────────────

  @doc """
  Begin a streamed completion. The CALLER is the httpc receiver: frames arrive
  as `{:http, {ref, :stream, bin}}`, then `:stream_end`, or `{:http, {ref,
  {:error, why}}}` — one process, one mailbox, nothing to orphan.

  Answers `{:ok, ref}` | `{:error, reason}`.
  """
  def stream_start(cfg, messages)

  def stream_start(%{transport: {:fake, payloads}}, _messages) do
    # Synthetic frames through the SAME mailbox protocol: the turn loop cannot
    # tell this from httpc, which is the point.
    ref = make_ref()
    body = Enum.map_join(payloads, "", &"data: #{&1}\n\n") <> "data: [DONE]\n\n"
    send(self(), {:http, {ref, :stream, body}})
    send(self(), {:http, {ref, :stream_end, []}})
    {:ok, ref}
  end

  def stream_start(cfg, messages) do
    body =
      JSON.encode!(%{
        model: cfg.model,
        messages: messages,
        stream: true,
        # An EMPTY tools array is not the same as no key (some providers reject
        # it), so the key is absent unless tools exist.
        tools: if(cfg[:tools] in [nil, []], do: nil, else: cfg.tools)
      })

    url = String.to_charlist("#{cfg.base_url}/chat/completions")

    headers = [
      {~c"authorization", String.to_charlist("Bearer #{cfg.key}")},
      {~c"accept", ~c"text/event-stream"}
    ]

    opts = [sync: false, stream: :self, receiver: self()]

    # httpc's per-request timeout: a reasoning model can take a minute to START
    # answering. The turn loop's own receive deadline is the outer bound.
    case :httpc.request(:post, {url, headers, ~c"application/json", body}, [timeout: 180_000], opts) do
      {:ok, ref} -> {:ok, ref}
      {:error, reason} -> {:error, "the request did not start: #{inspect(reason)}"}
    end
  end

  # ── the parser (pure) ─────────────────────────────────────────────────────

  @doc """
  Buffer + newly arrived binary → `{events, rest}`.

  An event is one SSE `data:` payload, decoded:

    * `{:delta, chunk}` — content arriving
    * `{:tool_delta, index, name_or_nil, arguments_chunk}` — a tool call being
      streamed (name arrives once, arguments in chunks)
    * `{:finish, reason}` — `finish_reason` set ("stop", "tool_calls", …)
    * `:done` — the terminal `[DONE]`
    * `:ignore` — pings, role frames, reasoning_content we do not surface

  Pure, because the fake exists to exercise THIS and only works if there is
  nothing between the bytes and the events to also test.
  """
  def parse_frame(buffer, bin) do
    parts = String.split(buffer <> bin, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)

    events =
      complete
      |> Enum.flat_map(&sse_data/1)
      |> Enum.flat_map(&decode_event/1)

    {events, rest}
  end

  defp sse_data(frame) do
    frame
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(&String.trim_leading(&1, "data:"))
    |> Enum.map(&String.trim/1)
  end

  defp decode_event("[DONE]"), do: [:done]

  defp decode_event(payload) do
    case JSON.decode(payload) do
      {:ok, %{"choices" => [choice | _]}} -> choice_events(choice)
      # a non-choice frame (usage trailers, error objects) is not the turn's
      # content; the stream_end/http-error path reports real failure.
      _ -> [:ignore]
    end
  end

  defp choice_events(%{"delta" => delta} = choice) do
    content =
      case Map.get(delta, "content") do
        c when is_binary(c) and c != "" -> [{:delta, c}]
        _ -> []
      end

    tools =
      for tc <- Map.get(delta, "tool_calls") || [] do
        fn_map = Map.get(tc, "function") || %{}
        {:tool_delta, Map.get(tc, "index", 0), Map.get(fn_map, "name"), Map.get(fn_map, "arguments", "")}
      end

    finish =
      case Map.get(choice, "finish_reason") do
        nil -> []
        reason -> [{:finish, reason}]
      end

    content ++ tools ++ finish
  end

  defp choice_events(_), do: [:ignore]
end
