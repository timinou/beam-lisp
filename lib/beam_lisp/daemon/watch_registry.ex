defmodule BeamLisp.Daemon.WatchRegistry do
  @moduledoc """
  Owns the daemon's live-reload watchers. `bl watch DIR` inside the daemon does
  not spawn its own VM-bound watcher; it registers here. The registry:

    * starts ONE `BeamLisp.ReloadWatcher` per canonical directory (deduping
      overlapping `bl watch` clients on the same tree),
    * injects an `:apply` callback that submits every stage→commit to the
      `Executor` FIFO — so a reload is ordered against the runs and tests the
      daemon is serving, never concurrent with a program mutating the image,
    * fans reload results out to every subscriber of that directory,
    * MONITORS each subscriber pid and removes ALL of that pid's subscriptions
      when it goes `:DOWN` — the listener tears a `bl watch` session down when
      its client disconnects, so its subscription leaves with it, and a
      directory's watcher stops when its last subscriber is gone.

  A subscriber is a `{pid, id}` (the connection handler + request id) that wants
  results. Callers pass a directory ALREADY made absolute against the client's
  cwd: the registry keys by the canonical spelling (`canonical/1` only resolves
  the final symlink component), and a client-relative path must never be
  resolved against the daemon's own working directory.
  """

  use GenServer

  # --- API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Register `subscriber` (any term, typically `{conn_pid, request_id}`) as a
  watcher of `dir` (absolute — see the moduledoc). Starts the watcher if this is
  the first subscriber. Returns `:ok` or `{:error, reason}` (e.g. FileSystem
  unavailable in this build).
  """
  def watch(server \\ __MODULE__, dir, subscriber, notify) when is_function(notify, 1) do
    GenServer.call(server, {:watch, canonical(dir), subscriber, notify})
  end

  @doc "Drop a subscriber; stop the watcher when its last subscriber leaves."
  def unwatch(server \\ __MODULE__, dir, subscriber) do
    GenServer.call(server, {:unwatch, canonical(dir), subscriber})
  end

  @doc "The set of watched directories (canonical)."
  def watched(server \\ __MODULE__) do
    GenServer.call(server, :watched)
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    # A watcher that cannot start (e.g. :file_system absent) exits abnormally,
    # and it is start_link'd from here: without trapping, the failed start would
    # take the whole registry down and with it every other watcher. Trapping
    # turns that EXIT into a message, so `watch/4` returns `{:error, reason}`.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       watchers: %{},
       subs: %{},
       # pid => {monitor_ref, subscription_count} — so a subscriber pid that is
       # gone has EVERY subscription removed, and a pid is only demonitored
       # once it holds none.
       pids: %{},
       executor: Keyword.get(opts, :executor, BeamLisp.Daemon.Executor)
     }}
  end

  @impl true
  def handle_call({:watch, dir, subscriber, notify}, _from, state) do
    case Map.get(state.watchers, dir) do
      nil ->
        case start_watcher(dir, state.executor, self()) do
          {:ok, pid} ->
            state = subscribe(state, dir, subscriber, notify)
            {:reply, :ok, %{state | watchers: Map.put(state.watchers, dir, pid)}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _pid ->
        {:reply, :ok, subscribe(state, dir, subscriber, notify)}
    end
  end

  @impl true
  def handle_call({:unwatch, dir, subscriber}, _from, state) do
    {:reply, :ok, unsubscribe(state, dir, subscriber)}
  end

  @impl true
  def handle_call(:watched, _from, state) do
    {:reply, Map.keys(state.watchers), state}
  end

  # A reload result from a watcher → fan out to that dir's subscribers.
  @impl true
  def handle_info({:reload_result, dir, result}, state) do
    for {_sub, notify} <- Map.get(state.subs, dir, %{}) do
      notify.(result)
    end

    {:noreply, state}
  end

  # A subscriber pid died: drop every subscription it held (possibly across
  # several directories, and several request ids on one directory), stopping
  # each watcher whose last subscriber just left.
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{state | pids: Map.delete(state.pids, pid)}
    {:noreply, drop_pid_subs(state, pid)}
  end

  # A watcher process died (its `FileSystem` child faulted, …). Drop the entry
  # so the NEXT subscriber for that dir starts a fresh watcher rather than
  # finding a stale pid and never watching. The subscriptions stay: they are
  # re-attached to the new watcher on the next `watch/4`.
  @impl true
  def handle_info({:EXIT, pid, _reason}, state) when is_pid(pid) do
    watchers = for {dir, wpid} <- state.watchers, wpid != pid, into: %{}, do: {dir, wpid}
    {:noreply, %{state | watchers: watchers}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- internals ---

  defp subscribe(state, dir, subscriber, notify) do
    subs = Map.update(state.subs, dir, %{subscriber => notify}, &Map.put(&1, subscriber, notify))
    monitor_subscriber(%{state | subs: subs}, subscriber)
  end

  defp unsubscribe(state, dir, subscriber) do
    state = demonitor_subscriber(state, subscriber)

    case Map.get(state.subs, dir, %{}) |> Map.delete(subscriber) do
      dir_subs when map_size(dir_subs) == 0 -> stop_dir(state, dir)
      dir_subs -> %{state | subs: Map.put(state.subs, dir, dir_subs)}
    end
  end

  defp monitor_subscriber(state, subscriber) do
    case subscriber_pid(subscriber) do
      nil ->
        state

      pid ->
        case Map.get(state.pids, pid) do
          nil -> %{state | pids: Map.put(state.pids, pid, {Process.monitor(pid), 1})}
          {ref, n} -> %{state | pids: Map.put(state.pids, pid, {ref, n + 1})}
        end
    end
  end

  defp demonitor_subscriber(state, subscriber) do
    case subscriber_pid(subscriber) do
      nil ->
        state

      pid ->
        case Map.get(state.pids, pid) do
          nil ->
            state

          {ref, 1} ->
            Process.demonitor(ref, [:flush])
            %{state | pids: Map.delete(state.pids, pid)}

          {ref, n} ->
            %{state | pids: Map.put(state.pids, pid, {ref, n - 1})}
        end
    end
  end

  defp drop_pid_subs(state, pid) do
    Enum.reduce(Map.keys(state.subs), state, fn dir, acc ->
      dir_subs = Map.get(acc.subs, dir, %{})

      kept =
        for {sub, notify} <- dir_subs, subscriber_pid(sub) != pid, into: %{}, do: {sub, notify}

      cond do
        map_size(kept) == map_size(dir_subs) -> acc
        map_size(kept) == 0 -> stop_dir(acc, dir)
        true -> %{acc | subs: Map.put(acc.subs, dir, kept)}
      end
    end)
  end

  defp stop_dir(state, dir) do
    case Map.get(state.watchers, dir) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      _ -> :ok
    end

    %{state | watchers: Map.delete(state.watchers, dir), subs: Map.delete(state.subs, dir)}
  end

  defp subscriber_pid({pid, _id}) when is_pid(pid), do: pid
  defp subscriber_pid(pid) when is_pid(pid), do: pid
  defp subscriber_pid(_), do: nil

  defp start_watcher(dir, executor, registry) do
    # The apply callback runs on the Executor FIFO and posts the result back to
    # the registry, which fans it out. `apply_change/3` is the watcher's own
    # in-process default; here we wrap it in a serialized executor job. The
    # saved path is folded into the result — the renderer's one place to see it.
    apply_fun = fn source, path, commit? ->
      result =
        BeamLisp.Daemon.Executor.run_reload(executor, fn ->
          BeamLisp.ReloadWatcher.apply_change(source, path, commit?)
        end)

      tagged = tag_path(result, path)
      send(registry, {:reload_result, dir, tagged})
      tagged
    end

    BeamLisp.ReloadWatcher.start_link(
      dirs: [dir],
      auto_commit: true,
      apply: apply_fun,
      # The registry runs ONE WATCHER PER DIRECTORY, so the watcher must not
      # take ReloadWatcher's default global name: with it, the SECOND
      # directory's start_link fails {:already_started, pid} and the tree
      # gets exactly one watched root, the rest refused.
      name: nil
    )
  rescue
    e -> {:error, Exception.message(e)}
  end

  # The result `bl.watch/render` sees: the commit status plus the saved path.
  # A non-map result — the watcher's `{:error, msg}` when a stage/commit raised —
  # is normalized to an `:error` result so the renderer has ONE shape.
  defp tag_path(%{} = result, path), do: Map.put(result, :path, path)

  defp tag_path(other, path),
    do: %{path: path, status: :error, errors: [%{kind: :error, msg: inspect(other)}]}

  # Canonical directory path (realpath when it exists), so two spellings of the
  # same dir share one watcher.
  defp canonical(dir) do
    case :file.read_link_all(String.to_charlist(Path.expand(dir))) do
      {:ok, target} -> List.to_string(target) |> Path.expand()
      _ -> Path.expand(dir)
    end
  end
end
