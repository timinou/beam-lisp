defmodule BeamLisp.Daemon.WatchRegistry do
  @moduledoc """
  Owns the daemon's live-reload watchers. `bl watch DIR` inside the daemon does
  not spawn its own VM-bound watcher; it registers here. The registry:

    * starts ONE `BeamLisp.Reload.Watcher` per canonical directory (deduping
      overlapping `bl watch` clients on the same tree),
    * injects an `:apply` callback that submits every stage→commit to the
      `Executor` FIFO — so a reload is ordered against the runs and tests the
      daemon is serving, never concurrent with a program mutating the image,
    * fans reload results out to every subscriber of that directory.

  A subscriber is a `{pid, id}` (the connection handler + request id) that wants
  `:watch` frames. When it drops, its subscription is removed; the watcher stays
  warm until no directory subscribers remain.
  """

  use GenServer

  # --- API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Register `subscriber` (any term, typically `{conn_pid, request_id}`) as a
  watcher of `dir`. Starts the watcher if this is the first subscriber. Returns
  `:ok` or `{:error, reason}` (e.g. FileSystem unavailable in this build).
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
    {:ok, %{watchers: %{}, subs: %{}, executor: Keyword.get(opts, :executor, BeamLisp.Daemon.Executor)}}
  end

  @impl true
  def handle_call({:watch, dir, subscriber, notify}, _from, state) do
    subs = Map.update(state.subs, dir, %{subscriber => notify}, &Map.put(&1, subscriber, notify))

    case Map.get(state.watchers, dir) do
      nil ->
        case start_watcher(dir, state.executor, self()) do
          {:ok, pid} ->
            {:reply, :ok, %{state | watchers: Map.put(state.watchers, dir, pid), subs: subs}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _pid ->
        {:reply, :ok, %{state | subs: subs}}
    end
  end

  @impl true
  def handle_call({:unwatch, dir, subscriber}, _from, state) do
    dir_subs = Map.get(state.subs, dir, %{}) |> Map.delete(subscriber)

    if map_size(dir_subs) == 0 do
      # last subscriber gone → stop the watcher
      case Map.get(state.watchers, dir) do
        pid when is_pid(pid) ->
          if Process.alive?(pid), do: GenServer.stop(pid, :normal)

        _ ->
          :ok
      end

      {:reply, :ok, %{state | watchers: Map.delete(state.watchers, dir), subs: Map.delete(state.subs, dir)}}
    else
      {:reply, :ok, %{state | subs: Map.put(state.subs, dir, dir_subs)}}
    end
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

  def handle_info(_msg, state), do: {:noreply, state}

  # --- internals ---

  defp start_watcher(dir, executor, registry) do
    # The apply callback runs on the Executor FIFO and posts the result back to
    # the registry, which fans it out. `apply_change/3` is the watcher's own
    # in-process default; here we wrap it in a serialized executor job.
    apply_fun = fn source, path, commit? ->
      result =
        BeamLisp.Daemon.Executor.run_reload(executor, fn ->
          BeamLisp.ReloadWatcher.apply_change(source, path, commit?)
        end)

      send(registry, {:reload_result, dir, result})
      result
    end

    BeamLisp.ReloadWatcher.start_link(
      dirs: [dir],
      auto_commit: true,
      apply: apply_fun
    )
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Canonical directory path (realpath when it exists), so two spellings of the
  # same dir share one watcher.
  defp canonical(dir) do
    case :file.read_link_all(String.to_charlist(Path.expand(dir))) do
      {:ok, target} -> List.to_string(target) |> Path.expand()
      _ -> Path.expand(dir)
    end
  end
end
