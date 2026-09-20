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

  ## Where the quiet window lives

  A save is many filesystem events, so they have to be folded into one commit
  once they stop. That is a DEBOUNCE, and the tree has exactly one implementation
  of it: `priv/std/proc/tick.bl`, whose `tick-reset` cancels the armed wake, arms
  a fresh one, and bumps a generation so a wake already in the mailbox is
  STALE. So this module does no timing of its own. It starts a
  `reload/watch-debounce` owner (a beam-lisp `defserver`, one per watcher),
  forwards every event to it, and applies what it holds when the owner answers
  `:flush_pending`.

  What stays here is the part that cannot leave: the pending set, the flush, and
  the injected `:apply` it runs — the daemon's variant submits the stage→commit
  to its Executor FIFO, so the commit must happen where the caller put it.

  The owner is not linked. If it dies, the pending paths are applied at once
  (nothing is stranded), and the next event starts a fresh owner.

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
    * `:apply` — optional 3-arg fn `(source, path, commit?) -> status`; the seam
      a host with its own ordering (the daemon's Executor FIFO) injects.
    * `:quiet_ms` — how long the paths must be quiet before the flush
      (default 50). The window is the bl-side owner's, not this module's.
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
    quiet_ms = Keyword.get(opts, :quiet_ms, 50)

    case start_debounce(quiet_ms) do
      {:ok, debounce} ->
        {:ok, fs} = FileSystem.start_link(dirs: dirs)
        FileSystem.subscribe(fs)

        state = %{
          fs: fs,
          auto_commit: Keyword.get(opts, :auto_commit, true),
          on_result: Keyword.get(opts, :on_result),
          # How a change is applied: `(source, path, commit?) -> result`. Defaults to
          # the in-process `apply_change/3`. The daemon injects a variant that
          # submits the reload to its Executor FIFO, so a stage->commit is ordered
          # against runs/tests in the same warm VM (no two things mutating the image
          # at once).
          apply: Keyword.get(opts, :apply, &apply_change/3),
          event_count: 0,
          last: :idle,
          # Debounce state: the paths with an unflushed event, and the bl-side
          # owner that decides when they have gone quiet. See `defer/2`.
          pending: %{},
          debounce: debounce,
          debounce_ref: Process.monitor(debounce),
          debounce_warned: false,
          quiet_ms: quiet_ms
        }

        {:ok, state}

      {:error, reason} ->
        # No quiet window means no way to act on a save. Refuse to come up at
        # all rather than watch a tree and drop every edit silently.
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:event_count, _from, state), do: {:reply, state.event_count, state}

  # `:drain` is a barrier: flush whatever the quiet window is still holding,
  # then answer — because file events and the flush are handled synchronously
  # in this GenServer's mailbox, by the time a `:drain` call is processed every
  # event ahead of it has already run. Returning `state.last` reports the
  # settled image.
  def handle_call(:drain, _from, state) do
    state = flush(state)
    {:reply, state.last, state}
  end

  @impl true
  def handle_info({:file_event, fs, {path, _events}}, %{fs: fs} = state) do
    state = %{state | event_count: state.event_count + 1}

    if watches?(path) do
      {:noreply, defer(path, state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:flush_pending, state), do: {:noreply, flush(state)}

  def handle_info({:file_event, fs, :stop}, %{fs: fs} = state) do
    {:noreply, state}
  end

  # The quiet-window owner died. Nothing is left holding the pending paths, so
  # apply them NOW — a save that never lands is the one outcome this may not
  # have — and drop the pid, so the next event starts a fresh owner. The watcher
  # survives its bl-side helper, which is the point: this is the door the image
  # heals through, and it may not be the thing that needs healing first.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{debounce_ref: ref} = state) do
    Logger.warning("reload watcher: quiet-window owner exited (#{inspect(reason)}); flushing held paths")
    {:noreply, flush(%{state | debounce: nil, debounce_ref: nil, debounce_warned: false})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # One save is many inotify events (create + write + attrib + close, more
  # under an editor's write-tmp/rename dance), and applying each one used to
  # run the full stage→commit per event: a single save committed the SAME
  # bundle 13 times on the reference host (blueprint FUP-020), and an event
  # landing between an editor's truncate and its write staged PARTIAL content
  # ("source declares no (ns …)"). So an event only RECORDS a path and resets
  # the quiet window; one flush then applies every pending path ONCE, from its
  # settled on-disk state.
  #
  # The window itself is `proc.tick`'s (see `priv/std/reload.bl` `watch-debounce`),
  # in a beam-lisp process the watcher owns: each event is forwarded there, and
  # it sends back `:flush_pending` once the paths have been quiet for `quiet_ms`.
  # Timing out of this module means one implementation of "wake me after quiet"
  # in the tree instead of two — and the ONE that resets on activity, so the
  # flush lands after the LAST event rather than the first.
  defp defer(path, state) do
    state = %{state | pending: Map.put(state.pending, path, true)}

    case arm(state) do
      {:ok, state} ->
        state

      {:unavailable, state} ->
        # A quiet window could not be started, so nothing will ever come back to
        # say "flush". Apply the save NOW: a tree that reloads a little too
        # eagerly is a bug, a tree whose saves never load is a broken tool.
        flush(state)
    end
  end

  # Reset the quiet window: tell the bl-side owner that a save is still being
  # written. A window already armed is reset, not duplicated — the owner cancels
  # its wake and arms a fresh one, and the wake already in ITS mailbox is made
  # stale by a generation bump (why `tick-reset` exists).
  defp arm(%{debounce: pid} = state) when is_pid(pid) do
    send(pid, {:"reload/activity", self()})
    {:ok, state}
  end

  defp arm(state) do
    case start_debounce(state.quiet_ms) do
      {:ok, pid} ->
        send(pid, {:"reload/activity", self()})
        {:ok, %{state | debounce: pid, debounce_ref: Process.monitor(pid), debounce_warned: false}}

      {:error, reason} ->
        unless state.debounce_warned do
          Logger.warning(
            "reload watcher: no quiet-window owner (#{reason}); applying each save as it arrives"
          )
        end

        {:unavailable, %{state | debounce: nil, debounce_ref: nil, debounce_warned: true}}
    end
  end

  # The quiet-window owner for this watcher — a beam-lisp `defserver` in the
  # `reload` namespace (see `priv/std/reload.bl`). One per watcher, unnamed: the
  # watcher holds the pid, and a name would be a second identity for one process.
  # A failure here is REPORTED, never stubbed with a local timer: two
  # implementations of one debounce is the thing this seam exists to abolish.
  defp start_debounce(quiet_ms) do
    BeamLisp.Loader.ensure_loaded("reload")
    {:ok, BeamLisp.RT.invoke(BeamLisp.Env.fetch!("reload", "watch-debounce-start"), [quiet_ms])}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def terminate(_reason, state) do
    # Stop the linked FileSystem worker so its `inotifywait` port does not leak
    # across tests (a lingering watcher on a removed tmp dir emits stray events).
    stop(state.fs)
    # …and the bl-side quiet-window owner, which is NOT linked to us: leave it
    # and it would keep a wake armed for a watcher that no longer exists.
    stop(state.debounce)
    :ok
  end

  defp stop(pid) when not is_pid(pid), do: :ok

  defp stop(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 500)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # Apply every quieted path ONCE, from its settled on-disk state. A path
  # that no longer exists was DELETED: staging would read nothing (or crash
  # File.read!), so it is reported as `:removed` — the namespace stays loaded
  # (no unload facility exists yet), but the watch log says what happened
  # instead of printing a stage error for a file that is simply gone.
  defp flush(state) do
    paths = state.pending
    state = %{state | pending: %{}}

    Enum.reduce(paths, state, fn {path, _}, acc ->
      if File.regular?(path) do
        handle_bl_change(path, acc)
      else
        notify(%{status: :removed, applied: [], errors: []}, path, acc)
      end
    end)
  end

  # Every result — applied, held, error, :removed — reaches the subscriber
  # channel through here: tagged with the saved path, normalized to a map (a
  # raised stage/commit comes back as the apply fun's {:error, msg}), so a
  # renderer always has ONE shape.
  defp notify(result, path, state) do
    tagged =
      case result do
        %{} = m -> Map.put_new(m, :path, path)
        other -> %{path: path, status: :error, errors: [%{kind: :error, msg: inspect(other)}]}
      end

    if state.on_result, do: state.on_result.(tagged)
    %{state | last: tagged}
  end

  # Stage the changed file into the reload bundle and (optionally) commit. The
  # bl-side `reload/stage` reads the ns from the source's `(ns …)`; a commit runs
  # the static coherence pass and either applies the edit or holds it with the
  # old code serving — exactly the reconcile-loop contract, driven by a save.
  defp handle_bl_change(path, state) do
    result = state.apply.(file_source(path), path, state.auto_commit)
    notify(result, path, state)
  end

  # Which file events the watcher reacts to: plain `.bl` sources and the two
  # literate dialects (`.bl.md`, `.bl.org`). The literate twins are the SAME
  # kind of save — a livebook doc is a namespace wearing prose (PLAN-069), so
  # saving one stages its program, not its prose.
  defp watches?(path), do: String.ends_with?(path, [".bl", ".bl.md", ".bl.org", ".clj", ".cljc"])

  # The source a file event stages: a plain `.bl` is itself; a literate file is
  # first recomposed to its program text — every code cell concatenated in
  # document order, the same minimal extraction the require path uses
  # (`BeamLisp.Loader.doc_source/2`, pinned equal to `bl.doc/doc-source`). The
  # reload bundle therefore stages the NAMESPACE the doc declares; prose never
  # enters the bundle.
  defp file_source(path) do
    raw = File.read!(path)

    cond do
      String.ends_with?(path, ".bl.md") -> BeamLisp.Loader.doc_source(raw, :md)
      String.ends_with?(path, ".bl.org") -> BeamLisp.Loader.doc_source(raw, :org)
      true -> raw
    end
  end

  @doc """
  Apply one source change through the reload loop and return the commit status —
  the exact reload integration a file save drives, WITHOUT the filesystem. Stage
  `source` into the bundle, then (when `commit?`) commit it: the static coherence
  pass applies the edit or HOLDS it with the old code serving. `label` is only
  used for a warning on error.

  This is the deterministic seam the FS watcher rides (`handle_bl_change` calls
  it) and the seam a test drives directly — proving the watcher's reload contract
  (stage → commit → applied|held) without inotify's timing. Returns the commit
  status map, or `{:error, msg}` if staging/committing raised.
  """
  def apply_change(source, label \\ "<source>", commit? \\ true) do
    escaped = escape_bl_string(source)

    try do
      _ = BeamLisp.eval(~s|(reload/stage "#{escaped}")|)

      if commit? do
        BeamLisp.eval("(reload/commit)")
      else
        BeamLisp.eval("(reload/status)")
      end
    rescue
      e ->
        Logger.warning("reload watcher: #{label}: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
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
