defmodule BeamLisp.WebSocket do
  @moduledoc """
  The runtime side of pure-beam-lisp WebSockets.

  OTP (and `WebSock`) require a *module* implementing the `WebSock`
  behaviour; a websocket handler cannot be a bare function. Rather than make
  every beam-lisp app generate its own module (as `defserver` does for
  gen_servers), this ONE adapter module implements the behaviour and delegates
  every callback to plain beam-lisp functions carried in the socket state.

  So the app is 100% beam-lisp: it hands `Adapter` a map of bl functions
  (`init` / `handle-in` / `handle-info`), and this module translates between
  WebSock's frame tuples and the bl world. The bl callbacks return the same
  ergonomic shapes a `defserver` uses — `[:push messages state]`,
  `[:ok state]`, `[:stop reason state]` — which `to_result/1` lowers to the
  exact `WebSock` return tuples.

  A frame arrives as `{:text, "…"}` / `{:binary, <<…>>}`; an outbound message
  is `{:text, iodata}` etc. The bl side speaks 2-tuples `[:text s]`, kept as
  beam-lisp vectors, and `normalize_msg/1` maps them to WebSock's tuples.
  """

  @behaviour WebSock

  # state = %{handlers: %{"handle-in" => fn, ...}, state: bl-state}

  @impl true
  def init(%{handlers: handlers} = wrap) do
    case Map.get(handlers, "init") do
      nil -> {:ok, wrap}
      f -> f |> invoke([wrap.state]) |> to_result(wrap)
    end
  end

  @impl true
  def handle_in({payload, [opcode: opcode]}, %{handlers: handlers} = wrap) do
    frame = frame_vector(opcode, payload)

    case Map.get(handlers, "handle-in") do
      nil -> {:ok, wrap}
      f -> f |> invoke([frame, wrap.state]) |> to_result(wrap)
    end
  end

  @impl true
  def handle_info(msg, %{handlers: handlers} = wrap) do
    case Map.get(handlers, "handle-info") do
      nil -> {:ok, wrap}
      f -> f |> invoke([msg, wrap.state]) |> to_result(wrap)
    end
  end

  @impl true
  def terminate(reason, %{handlers: handlers} = wrap) do
    case Map.get(handlers, "terminate") do
      nil -> :ok
      f -> invoke(f, [reason, wrap.state]) && :ok
    end
  end

  # ── bl-result → WebSock tuple ─────────────────────────────────────────

  # The bl callbacks return a beam-lisp vector shaped like a defserver return:
  #   [:ok state]                     → {:ok, %{wrap | state: state}}
  #   [:push messages state]          → {:push, msgs, %{wrap | state: state}}
  #   [:reply _term messages state]   → {:push, msgs, %{wrap | state: state}}
  #   [:stop reason state]            → {:stop, reason, %{wrap | state: state}}
  # A bare value (not a tagged vector) is treated as the new state (`:ok`).
  defp to_result(result, wrap) do
    case as_list(result) do
      [:ok, state] -> {:ok, put(wrap, state)}
      ["ok", state] -> {:ok, put(wrap, state)}
      [:push, msgs, state] -> {:push, normalize_msgs(msgs), put(wrap, state)}
      ["push", msgs, state] -> {:push, normalize_msgs(msgs), put(wrap, state)}
      [:reply, _t, msgs, state] -> {:push, normalize_msgs(msgs), put(wrap, state)}
      ["reply", _t, msgs, state] -> {:push, normalize_msgs(msgs), put(wrap, state)}
      [:stop, reason, state] -> {:stop, atom(reason), put(wrap, state)}
      ["stop", reason, state] -> {:stop, atom(reason), put(wrap, state)}
      _ -> {:ok, put(wrap, result)}
    end
  end

  defp put(wrap, state), do: %{wrap | state: state}

  # ── frame helpers ─────────────────────────────────────────────────────

  # an inbound frame as a beam-lisp vector [:text "…"] / [:binary <<…>>]
  defp frame_vector(opcode, payload), do: BeamLisp.Vector.new([opcode, payload])

  defp normalize_msgs(msgs) do
    msgs
    |> as_list()
    |> case do
      # a single [:text s] vector, not a list of them
      [op, data] when op in [:text, :binary, :ping, :pong] or op in ~w(text binary ping pong) ->
        [normalize_msg([op, data])]

      list ->
        Enum.map(list, &normalize_msg/1)
    end
  end

  defp normalize_msg(msg) do
    case as_list(msg) do
      [op, data] -> {atom(op), data}
      other -> other
    end
  end

  # ── coercions ─────────────────────────────────────────────────────────

  defp as_list(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp as_list(list) when is_list(list), do: list
  defp as_list(other), do: other

  defp atom(a) when is_atom(a), do: a
  defp atom(s) when is_binary(s), do: String.to_atom(s)

  defp invoke(f, args), do: BeamLisp.RT.invoke(f, args)

  @doc """
  Build the adapter's initial state from a beam-lisp handler map and a
  user init argument. Used by the `websocket` bl namespace at upgrade time.
  """
  def wrap(handlers, user_state) when is_map(handlers) do
    # bl keyword map keys are inconsistent across the atom-table boundary: a
    # single-word `:init` interns as the atom `:init`, but a hyphenated
    # `:handle-in` arrives as the string "handle-in". Normalize every key to a
    # string so the callback lookups (`Map.get(handlers, "handle-in")`) are
    # uniform regardless of how the key crossed.
    normalized = for {k, v} <- handlers, into: %{}, do: {to_string(k), v}
    %{handlers: normalized, state: user_state}
  end
end
