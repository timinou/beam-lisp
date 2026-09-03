defmodule BeamLisp.Daemon.Protocol do
  @moduledoc """
  The wire protocol between the native `bl` launcher and a warm daemon.

  Every frame on the `AF_UNIX` `{packet, 4}` stream is ONE Erlang term (ETF).
  The daemon decodes with `:erlang.binary_to_term(bin, [:safe])` so a malicious
  client cannot force atom-table growth or load a foreign function, then runs
  the term through `validate/1` — a total, allowlisted, depth-bounded schema
  check. A frame that does not match a known shape is rejected, never executed.

  Frame shapes (version 1). `id` is a 16-byte request id; strings are binaries.

    client → server
      {:bl, 1, :hello,   %{tree: <<32 bytes>>, token: <<32 bytes>>,
                          compiler_key: <<hex>>, daemon_build_id: <<hex>>}}
      {:bl, 1, :request, id, %{argv: [binary], cwd: binary,
                               env_paths: [binary], tty: map}}
      {:bl, 1, :stdin_reply, id, seq, binary | :eof}
      {:bl, 1, :control, id, :status | :stop}

    server → client
      {:bl, 1, :ready,     meta_map}
      {:bl, 1, :reject,    reason_atom, message_binary, meta_map}
      {:bl, 1, :accepted,  id, %{queue_position: n}}
      {:bl, 1, :stdout,    id, seq, binary}
      {:bl, 1, :stderr,    id, seq, binary}
      {:bl, 1, :stdin,     id, seq, prompt_or_count}
      {:bl, 1, :watch,     id, seq, %{path: binary, result: term}}
      {:bl, 1, :heartbeat, id, monotonic_ms}
      {:bl, 1, :exit,      id, code}
      {:bl, 1, :failed,    id, code, message_binary}
  """

  @version 1
  @max_frame 16_777_216
  @max_argv 4_096
  @max_path_len 4_096
  @reject_reasons ~w(unauthorized wrong_tree protocol_mismatch restart_required shutting_down malformed)a

  def version, do: @version
  def max_frame, do: @max_frame

  # --- encode (server side; the launcher re-implements a fixed subset) ---

  def encode(term), do: :erlang.term_to_binary(term)

  def ready(meta), do: encode({:bl, @version, :ready, meta})
  def reject(reason, msg, meta \\ %{}) when reason in @reject_reasons,
    do: encode({:bl, @version, :reject, reason, to_string(msg), meta})

  def accepted(id, pos), do: encode({:bl, @version, :accepted, id, %{queue_position: pos}})
  def stdout(id, seq, bytes), do: encode({:bl, @version, :stdout, id, seq, bytes})
  def stderr(id, seq, bytes), do: encode({:bl, @version, :stderr, id, seq, bytes})
  def stdin_req(id, seq, prompt), do: encode({:bl, @version, :stdin, id, seq, prompt})
  def watch(id, seq, payload), do: encode({:bl, @version, :watch, id, seq, payload})
  def heartbeat(id), do: encode({:bl, @version, :heartbeat, id, System.monotonic_time(:millisecond)})
  def exit(id, code), do: encode({:bl, @version, :exit, id, code})
  def failed(id, code, msg), do: encode({:bl, @version, :failed, id, code, to_string(msg)})

  # --- decode + validate (server side; total, allowlisted) ---

  @doc """
  Decode one frame payload. Returns `{:ok, validated_term}` or
  `{:error, reason}`. Refuses oversized frames, non-ETF bytes, unsafe terms
  (atoms not already in the table), and any shape outside the schema.
  """
  def decode(bin) when is_binary(bin) do
    cond do
      byte_size(bin) > @max_frame ->
        {:error, :frame_too_large}

      true ->
        try do
          term = :erlang.binary_to_term(bin, [:safe])
          validate(term)
        rescue
          _ -> {:error, :malformed}
        catch
          _, _ -> {:error, :malformed}
        end
    end
  end

  @doc "Total schema validation of a decoded client frame."
  def validate({:bl, @version, :hello, %{tree: tree, token: token} = m})
      when is_binary(tree) and byte_size(tree) == 32 and
             is_binary(token) and byte_size(token) == 32 do
    ck = Map.get(m, :compiler_key)
    bid = Map.get(m, :daemon_build_id)

    if opt_bin(ck) and opt_bin(bid) do
      {:ok, {:hello, %{tree: tree, token: token, compiler_key: ck, daemon_build_id: bid}}}
    else
      {:error, :malformed}
    end
  end

  def validate({:bl, @version, :request, id, %{argv: argv, cwd: cwd} = m})
      when is_binary(id) and byte_size(id) == 16 and is_list(argv) and is_binary(cwd) do
    env_paths = Map.get(m, :env_paths, [])
    tty = Map.get(m, :tty, %{})

    cond do
      length(argv) > @max_argv -> {:error, :argv_too_long}
      not Enum.all?(argv, &valid_arg?/1) -> {:error, :malformed}
      byte_size(cwd) > @max_path_len -> {:error, :malformed}
      not (is_list(env_paths) and Enum.all?(env_paths, &valid_arg?/1)) -> {:error, :malformed}
      not is_map(tty) -> {:error, :malformed}
      true -> {:ok, {:request, id, %{argv: argv, cwd: cwd, env_paths: env_paths, tty: tty}}}
    end
  end

  def validate({:bl, @version, :stdin_reply, id, seq, data})
      when is_binary(id) and is_integer(seq) and (is_binary(data) or data == :eof) do
    {:ok, {:stdin_reply, id, seq, data}}
  end

  def validate({:bl, @version, :control, id, op})
      when is_binary(id) and op in [:status, :stop] do
    {:ok, {:control, id, op}}
  end

  def validate(_), do: {:error, :unknown_frame}

  defp opt_bin(nil), do: true
  defp opt_bin(v) when is_binary(v), do: true
  defp opt_bin(_), do: false

  defp valid_arg?(a), do: is_binary(a) and byte_size(a) <= @max_path_len
end
