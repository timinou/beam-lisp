defmodule BeamLisp.Daemon.IO do
  @moduledoc """
  A per-request group-leader proxy that turns the Erlang I/O protocol into
  daemon wire frames. A command worker's `Process.group_leader/0` is set to a
  process running `loop/1`; every `IO.puts`, `IO.write`, printed value, and
  `IO.gets` the beam-lisp program performs then becomes a `:stdout` / `:stderr`
  / `:stdin` frame on the client's socket.

  Output is chunked ≤64 KiB and handed SYNCHRONOUSLY to the socket writer, so a
  slow or dead client applies backpressure (the worker blocks on a full socket
  buffer) instead of growing the daemon's heap without bound. `:standard_error`
  is a globally-named device, not per-group-leader, so a separate multiplexer
  (installed once, daemon-lifetime) routes stderr by the writing process's
  group leader — that lives in `BeamLisp.Daemon.StdErr`.

  The proxy owns the socket for the request's lifetime. It sequences stdout and
  stderr with a shared monotonic counter so the client can interleave them in
  causal order.
  """

  alias BeamLisp.Daemon.Protocol

  @chunk 64 * 1024

  @doc """
  Spawn a group-leader proxy for request `id` writing to `sock`. Returns the
  proxy pid; set a worker's group leader to it with `:erlang.group_leader/2`.
  `parent` is notified `{:io_seq, id, next_seq}` on close so the executor can
  order the terminal frame after the last output.
  """
  def start(sock, id, parent) do
    spawn_link(fn -> loop(%{sock: sock, id: id, parent: parent, seq: 0, stdin_seq: 0}) end)
  end

  @doc "Flush + tell the proxy no more output is coming; returns the final seq."
  def finish(proxy) do
    ref = make_ref()
    send(proxy, {:finish, self(), ref})

    receive do
      {:finished, ^ref, seq} -> seq
    after
      5_000 -> 0
    end
  end

  # --- the I/O server loop ---

  def loop(state) do
    receive do
      {:io_request, from, reply_as, req} ->
        {reply, state} = handle_io(req, state)
        send(from, {:io_reply, reply_as, reply})
        loop(state)

      {:finish, from, ref} ->
        send(from, {:finished, ref, state.seq})
        :ok

      _other ->
        loop(state)
    end
  end

  # put_chars variants → stdout frames
  defp handle_io({:put_chars, _enc, chars}, state), do: {:ok, emit(state, :stdout, chars)}
  defp handle_io({:put_chars, _enc, mod, fun, args}, state) do
    {:ok, emit(state, :stdout, apply(mod, fun, args))}
  end
  defp handle_io({:put_chars, chars}, state), do: {:ok, emit(state, :stdout, chars)}
  defp handle_io({:put_chars, mod, fun, args}, state) do
    {:ok, emit(state, :stdout, apply(mod, fun, args))}
  end

  # get_line / get_chars → request stdin from the client, block for the reply
  defp handle_io({:get_line, _enc, prompt}, state), do: request_stdin(state, prompt)
  defp handle_io({:get_line, prompt}, state), do: request_stdin(state, prompt)
  defp handle_io({:get_chars, _enc, prompt, _n}, state), do: request_stdin(state, prompt)
  defp handle_io({:get_chars, prompt, _n}, state), do: request_stdin(state, prompt)

  defp handle_io({:get_until, _enc, prompt, _m, _f, _a}, state), do: request_stdin(state, prompt)
  defp handle_io({:get_until, prompt, _m, _f, _a}, state), do: request_stdin(state, prompt)

  defp handle_io({:setopts, _opts}, state), do: {:ok, state}
  defp handle_io(:getopts, state), do: {[binary: true, encoding: :unicode], state}
  defp handle_io({:get_geometry, :columns}, state), do: {80, state}
  defp handle_io({:get_geometry, :rows}, state), do: {24, state}
  defp handle_io({:requests, reqs}, state), do: handle_many(reqs, state)
  defp handle_io(_other, state), do: {{:error, :request}, state}

  defp handle_many([], state), do: {:ok, state}
  defp handle_many([req | rest], state) do
    case handle_io(req, state) do
      {:ok, state} -> handle_many(rest, state)
      {_reply, state} -> handle_many(rest, state)
    end
  end

  # --- emit + stdin ---

  defp emit(state, stream, chars) do
    bin = :erlang.iolist_to_binary(normalize(chars))
    send_chunks(state, stream, bin)
  end

  defp normalize(chars) when is_list(chars) or is_binary(chars), do: chars
  defp normalize(other), do: :io_lib.format("~p", [other])

  defp send_chunks(state, _stream, <<>>), do: state
  defp send_chunks(state, stream, bin) do
    <<chunk::binary-size(min(@chunk, byte_size(bin))), rest::binary>> = bin
    frame =
      case stream do
        :stdout -> Protocol.stdout(state.id, state.seq, chunk)
        :stderr -> Protocol.stderr(state.id, state.seq, chunk)
      end

    # synchronous send = bounded backpressure
    _ = :gen_tcp.send(state.sock, frame)
    send_chunks(%{state | seq: state.seq + 1}, stream, rest)
  end

  defp request_stdin(state, prompt) do
    seq = state.stdin_seq
    prompt_bin = :erlang.iolist_to_binary(normalize(prompt || ""))
    _ = :gen_tcp.send(state.sock, Protocol.stdin_req(state.id, seq, prompt_bin))
    state = %{state | stdin_seq: seq + 1}

    # block for the client's stdin_reply on the SAME socket, routed here by the
    # connection handler as a message.
    receive do
      {:stdin_reply, ^seq, :eof} -> {:eof, state}
      {:stdin_reply, ^seq, data} when is_binary(data) -> {data, state}
    after
      120_000 -> {:eof, state}
    end
  end
end
