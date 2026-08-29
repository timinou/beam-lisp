defmodule BeamLisp.ReloadWatcher do
  @moduledoc """
  The dev-only live-reload watcher: it turns a `.bl` file save into a staged
  edit on the reload bundle, then commits it — so editing a source file updates
  the running image, coherently, with no restart.

  This is the proactive face of the drift gate in `BeamLisp.AOT` (Wave 1): that
  gate heals a STALE beam on the next load; this watcher heals the LIVE image the
  instant the source changes. Both keep one source of truth between files and
  runtime.

  ## Determinism — why a watcher does not make tests flaky

  Filesystem events are asynchronous, which is the usual reason FS-driven tests
  sleep-and-hope. This watcher is a GenServer whose `drain/1` is a **synchronous
  call**: it returns only after every file event received so far has been staged
  and committed. A test writes a file, calls `sync/1` (which itself waits for the
  event to arrive) then `drain/1`, and observes the settled image deterministically
  — no `Process.sleep`. The reload module's own `reload/drain` is the bl-side
  barrier that pairs with this.

  ## Scope

  Dev + test only. Production trusts compiled beams and runs no watcher — the
  guarantee lives in the running image, not the build. Start it explicitly with a
  set of directories to watch; it is not in the supervision tree.
  """

  use GenServer
  require Logger

  @doc """
  Start watching `dirs` (a list of directories) for `.bl` changes. Options:

    * `:dirs` — directories to watch (required)
    * `:name` — GenServer name (default `#{inspect(__MODULE__)}`)
    * `:auto_commit` — commit after staging each change (default `true`); when
      `false`, changes are staged and a caller drives `reload/commit` itself.
    * `:on_result` — optional 1-arg fn called with each commit's status map
      (for tests/observability).
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Block until the watcher has processed every filesystem event delivered up to
  now, then return the last commit status (or `:idle`). This is the deterministic
  settle point: after `sync/1` returns, the running image reflects every save the
  OS has reported. Pair with a short wait for the event to be *emitted* — see
  `sync/2`.
  """
  def drain(name \\ __MODULE__), do: GenServer.call(name, :drain)

  @doc """
  Deterministic test helper: wait up to `timeout` ms for the watcher to observe
  at least `n` more file events than it had when called, then drain. Returns the
  last commit status. Avoids `Process.sleep`-and-hope by counting real events.
  """
  def sync(name \\ __MODULE__, opts \\ []) do
    n = Keyword.get(opts, :events, 1)
    timeout = Keyword.get(opts, :timeout, 2000)
    base = GenServer.call(name, :event_count)
    wait_for_events(name, base + n, timeout)
    drain(name)
  end

  defp wait_for_events(_name, _target, timeout) when timeout <= 0, do: :timeout

  defp wait_for_events(name, target, timeout) do
    if GenServer.call(name, :event_count) >= target do
      :ok
    else
      Process.sleep(10)
      wait_for_events(name, target, timeout - 10)
    end
  end

  # ── server ────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    dirs = Keyword.fetch!(opts, :dirs)
    {:ok, fs} = FileSystem.start_link(dirs: dirs)
    FileSystem.subscribe(fs)

    state = %{
      fs: fs,
      auto_commit: Keyword.get(opts, :auto_commit, true),
      on_result: Keyword.get(opts, :on_result),
      event_count: 0,
      last: :idle
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:event_count, _from, state), do: {:reply, state.event_count, state}

  # `:drain` is a no-op barrier: because file events are handled synchronously in
  # this GenServer's mailbox, by the time a `:drain` call is processed every event
  # ahead of it has already run. Returning `state.last` reports the settled image.
  def handle_call(:drain, _from, state), do: {:reply, state.last, state}

  @impl true
  def handle_info({:file_event, fs, {path, _events}}, %{fs: fs} = state) do
    state = %{state | event_count: state.event_count + 1}

    if String.ends_with?(path, ".bl") and File.regular?(path) do
      {:noreply, handle_bl_change(path, state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, fs, :stop}, %{fs: fs} = state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Stop the linked FileSystem worker so its `inotifywait` port does not leak
    # across tests (a lingering watcher on a removed tmp dir emits stray events).
    if is_pid(state.fs) and Process.alive?(state.fs) do
      try do
        GenServer.stop(state.fs, :normal, 500)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # Stage the changed file into the reload bundle and (optionally) commit. The
  # bl-side `reload/stage` reads the ns from the source's `(ns …)`; a commit runs
  # the static coherence pass and either applies the edit or holds it with the
  # old code serving — exactly the reconcile-loop contract, driven by a save.
  defp handle_bl_change(path, state) do
    source = File.read!(path)
    escaped = escape_bl_string(source)

    result =
      try do
        _ = BeamLisp.eval(~s|(reload/stage "#{escaped}")|)

        if state.auto_commit do
          BeamLisp.eval("(reload/commit)")
        else
          BeamLisp.eval("(reload/status)")
        end
      rescue
        e ->
          Logger.warning("reload watcher: #{Path.relative_to_cwd(path)}: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      end

    if state.on_result, do: state.on_result.(result)
    %{state | last: result}
  end

  # Encode a source string as a bl double-quoted literal: escape backslashes and
  # quotes so the file's own text survives being embedded in an `(reload/stage "…")`
  # form. Newlines are legal inside a bl string, so they pass through unescaped.
  defp escape_bl_string(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
