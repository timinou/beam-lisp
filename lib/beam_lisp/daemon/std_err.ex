defmodule BeamLisp.Daemon.StdErr do
  @moduledoc """
  The daemon-lifetime owner of the globally-named `:standard_error` device, so a
  command's stderr reaches its CLIENT.

  ## The gap this closes

  A command worker's group leader is its request's `BeamLisp.Daemon.IO` proxy, so
  everything the program prints on stdout becomes a wire frame. stderr is not
  group-leader-scoped: `IO.puts(:stderr, …)` resolves the atom `:standard_error`
  through `Process.whereis/1` and writes THERE, which is the VM's own fd 2 — the
  daemon's log file. A command's `u/io-err` line therefore reached nobody, and
  the failure is invisible by construction: the client gets no frame, and the
  line lands in a file nobody is looking at. Measured before this existed:
  `bl open nope` under the session printed NOTHING, while cold it printed
  `bl: nothing holds the name "nope" — is the session running?`.

  ## The rule

  ONE device, routed by the writing process's group leader — the same rule
  stdout already follows:

    * a writer whose group leader is a request proxy (`BeamLisp.Daemon.IO`) has
      its bytes handed to THAT proxy, to become a `:stderr` frame on that
      request's socket, sequenced with the request's stdout so a client can
      interleave them in causal order;
    * every other writer — the daemon's own Logger, the watcher, a process
      lingering from a finished request — is forwarded to the device that WAS
      registered under this name, so the daemon's diagnostics keep going where
      they always went.

  The daemon runs one command at a time (`Executor` is a FIFO), so "the process
  whose group leader is a proxy" identifies a request unambiguously.

  ## Why the name is taken rather than a second device offered

  `:standard_error` is what the language's own `u/io-err`, Elixir's crash
  reports, `IO.warn`, and every `:io.put_chars(:standard_error, …)` in the
  ecosystem already name. Asking callers to write through a daemon-specific
  device would have to be adopted one call site at a time, and the ones it
  missed would keep disappearing — which is the bug.

  The displaced device is remembered in `:persistent_term`, not in this
  process's state, so a crash and restart of this worker re-registers the name
  and still knows where non-command stderr goes.
  """

  use GenServer

  @device_key {__MODULE__, :device}
  @name :standard_error

  # --- public API ---

  def start_link(opts \\ []) do
    # NAMELESS on purpose: an Erlang process may hold exactly ONE registered
    # name, and this one's job is to hold `:standard_error`. Giving it the
    # module name as well is not a second handle, it is a failure to start
    # (`:erlang.register/2` refuses a process that already has a name).
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Take the `:standard_error` name, remembering the device it replaces.
  Idempotent: `already_started` means this VM already routes stderr.
  """
  def install(opts \\ []) do
    case start_link(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc "The device non-command stderr is forwarded to (`nil` when none was found)."
  def device, do: :persistent_term.get(@device_key, nil)

  @doc """
  The request proxy whose stderr stream a write by `pid` belongs to, or nil when
  `pid` writes on the daemon's own account.

  Found through the WRITER'S GROUP LEADER, which is the same rule stdout
  follows: a command's writer has the request's `BeamLisp.Daemon.IO` proxy as its
  group leader, so the stream is that request's. Looking in the writer's own
  process dictionary would answer "not a proxy" for every command, because the
  marker is set on the proxy — one level up, where the socket lives.
  """
  def proxy_of(pid) when is_pid(pid) do
    with {:group_leader, gl} when is_pid(gl) <- Process.info(pid, :group_leader),
         {:dictionary, dict} <- Process.info(gl, :dictionary),
         {_, proxy} when is_pid(proxy) <- List.keyfind(dict, :beam_lisp_io_proxy, 0) do
      proxy
    else
      _ -> nil
    end
  end

  def proxy_of(_), do: nil

  # --- the device loop ---

  @impl true
  def init(_opts) do
    # TRAP EXITS, or the handback in `terminate/2` never runs: a supervisor stops
    # a child with `Process.exit(pid, :shutdown)`, and a process that does not
    # trap it dies WITHOUT calling terminate — leaving the VM with NO stderr
    # device at all, so every later `IO.puts(:stderr, …)` raises in its caller.
    # That is strictly worse than the bug this module fixes, which is why the
    # handback has its own test.
    Process.flag(:trap_exit, true)

    if replace() do
      {:ok, %{}}
    else
      # Someone else holds the name and will not give it up. Better to not be in
      # the tree at all than to swallow stderr by accident.
      {:stop, :name_taken}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    # Hand the name back to the device we displaced. A daemon that lost this
    # worker would otherwise have NO stderr device at all, and every later
    # `IO.puts(:stderr, …)` would raise inside its caller.
    case device() do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          Process.unregister(@name)
          :erlang.register(@name, pid)
        end

      _ ->
        :ok
    end
  end

  @impl true
  def handle_info({:io_request, from, reply_as, req}, state) do
    # `from` IS the writer: the io protocol sends
    # `{:io_request, self(), reply_as, req}` to the device, so the process that
    # called `io:put_chars` is right here. That is how stderr is routed by
    # GROUP LEADER without a registry.
    send(from, {:io_reply, reply_as, handle_io(req, from)})
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Take the name from whoever holds it. `register/2` fails when the name is
  # taken, so the old device is captured first and kept for the forward path.
  defp replace do
    case Process.whereis(@name) do
      nil ->
        case device() do
          nil -> register_maybe(nil)
          pid -> register_maybe(pid)
        end

      pid when pid == self() ->
        true

      pid ->
        # Usually the kernel's own stderr process, which cannot be asked to step
        # aside; `unregister` frees the name from our side. This runs before any
        # command, so there is no writer mid-flight to lose.
        :persistent_term.put(@device_key, pid)
        Process.unregister(@name)
        register_maybe(pid)
    end
  end

  defp register_maybe(prev) do
    case :erlang.register(@name, self()) do
      true ->
        if prev, do: :persistent_term.put(@device_key, prev)
        true

      _ ->
        false
    end
  end

  # --- the io protocol ---

  defp handle_io({:put_chars, enc, chars}, from), do: route(to_chars(enc, chars), from)
  defp handle_io({:put_chars, enc, mod, fun, args}, from), do: route(to_chars(enc, {mod, fun, args}), from)
  defp handle_io({:put_chars, chars}, from), do: route(chars, from)
  defp handle_io({:put_chars, mod, fun, args}, from), do: route({mod, fun, args}, from)

  defp handle_io({:requests, reqs}, from) do
    Enum.each(reqs, &handle_io(&1, from))
    :ok
  end

  defp handle_io(:getopts, _from), do: [binary: true, encoding: :unicode]
  defp handle_io({:setopts, _opts}, _from), do: :ok
  defp handle_io({:get_geometry, :columns}, _from), do: 80
  defp handle_io({:get_geometry, :rows}, _from), do: 24
  # Reading stderr is not something anyone does on purpose; answering EOF beats
  # crashing the device out from under a caller that tried.
  defp handle_io({:get_line, _enc, _prompt}, _from), do: :eof
  defp handle_io({:get_line, _prompt}, _from), do: :eof
  defp handle_io({:get_chars, _enc, _prompt, _n}, _from), do: :eof
  defp handle_io({:get_chars, _prompt, _n}, _from), do: :eof
  defp handle_io({:get_until, _enc, _prompt, _m, _f, _a}, _from), do: :eof
  defp handle_io({:get_until, _prompt, _m, _f, _a}, _from), do: :eof
  defp handle_io(_other, _from), do: :ok

  defp to_chars(_enc, {mod, fun, args}), do: apply(mod, fun, args)
  defp to_chars(_enc, chars), do: chars

  defp route(chars, from) do
    bin = :erlang.iolist_to_binary(normalize(chars))

    case proxy_of(from) do
      nil -> forward(bin)
      proxy -> BeamLisp.Daemon.IO.stderr(proxy, bin)
    end

    :ok
  end

  defp normalize(chars) when is_binary(chars) or is_list(chars), do: chars
  defp normalize(other), do: :io_lib.format("~p", [other])

  # Everything that is not a command's stderr: the daemon's own diagnostics.
  # Forwarded to the device we displaced, so the log keeps them.
  defp forward(bin) do
    case device() do
      pid when is_pid(pid) ->
        send(pid, {:io_request, self(), make_ref(), {:put_chars, :unicode, bin}})

      _ ->
        :ok
    end
  end
end
