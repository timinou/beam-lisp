defmodule BeamLisp.Daemon.IndexWorker do
  # `is_bl_map/1` is a defguard — a macro — so it must be required before use in
  # a guard clause.
  require BeamLisp.Guards

  @moduledoc """
  Owns the tree's code index — the one conn every code question reads.

  ## Why this module exists

  A datom conn's store is an ETS table, and an ETS table lives exactly as long
  as the process that created it. That single fact is why every code question
  used to pay for its own index:

    * `bl ask` built one (or reopened an `askset.<path-set>.fjall` — a new set
      hash on every edit, so an edit re-indexed the whole corpus);
    * `bl search` built one (`manifest.<corpus>.term` read in 30 ms, then every
      fact pushed through `datom/transact!` again — 41 s on blueprint's 43
      sources);
    * the HTTP MCP tool built one inside the PER-REQUEST connection process, so
      the memo it already had died with the response (FUP-022: two identical
      `code/ask` POSTs took 79 s then 95 s, while the same question through a
      warm CLI took 3 s).

  The fix is ownership, not caching. A source's analysis is a pure function of
  its bytes and is already cached to disk per file; what was missing was a
  process to HOLD the assembled conn between questions. This worker is that
  process. Every door asks `code.index/ensure-tree`, which runs on this worker
  when it exists, so one build serves them all.

  ## What it owns

    * the beam-lisp index (`code.index/ensure-tree`), rebuilt only when a
      source's bytes moved;
    * a public ETS row describing that build: its phase, how many files are
      done, which file is in flight, how long the last build took and what it
      produced. The dashboard renders it (see `BeamLisp.Daemon.HTTP`), which is
      what makes a background build VISIBLE rather than minutes of silence. The
      row is ETS and not a `GenServer.call` on purpose: reading progress must
      never queue behind the build it reports on.

  ## Serialization

  Requests serialize on the worker, which is the honest shape of the resource:
  one index, one owner, one build at a time. A build runs INSIDE `handle_info`,
  so a `run/1` that arrives mid-build waits for it — and then finds a warm index,
  because the build it waited for is the one it wanted.

  A worker crash restarts it (`BeamLisp.Daemon.Workers`) and the next request
  re-mounts; the memo's `datom/alive?` check was built for exactly that.
  """

  use GenServer

  @table :bl_index_progress

  # --- public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Run `fun` on the index-owning process and hand back its result.

  The whole contract is WHERE the function runs: anything the function builds
  (a datom conn, its ETS tables) is owned by this worker and therefore survives
  the caller. No timeout — a first build on a cold tree is minutes on a large
  tree, and a caller that wants to watch reads `progress/0` meanwhile.
  """
  def run(fun, server \\ __MODULE__) when is_function(fun, 0) do
    GenServer.call(server, {:run, fun}, :infinity)
  end

  @doc """
  The build's current state as a map, off the ETS row — `%{phase: :cold |
  :building | :ready | :error, done: n, total: n, file: path, ms: ms}`.

  Never blocks and never queues: `run/1` does, and a pane that waits for the
  build it is reporting on could not report on it.
  """
  def progress do
    case :ets.lookup(@table, :progress) do
      [{:progress, m}] -> m
      [] -> cold()
    end
  rescue
    ArgumentError -> cold()
  end

  defp cold, do: %{phase: :cold, done: 0, total: 0, file: nil}

  @doc """
  Record one progress frame, as `code.index` reported it.

  The single writer is the beam-lisp build (which runs on this process, so the
  write is local). Total on purpose: a build must never fail because the UI
  could not be told about it, so a frame this does not understand is still
  stored — the dashboard renders what it finds and ignores what it does not.
  """
  def progress!(frame) when BeamLisp.Guards.is_bl_map(frame) do
    :ets.insert(@table, {:progress, row(frame)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # One row shape, whichever frame arrived. A build reports itself as `:start`
  # and then `:file` while it runs; a reader that matched on `:building` would
  # fall through to "nothing indexed" in the middle of a build — the one moment
  # the row exists for. The worker is the row's single writer, so the mapping
  # from a build's frames to a readable one lives here, not in each reader (the
  # dashboard, `/model`, `bl daemon status` and `bl ui` all render this shape).
  defp row(f) do
    now = System.system_time(:millisecond)

    case Map.get(f, :phase) do
      :start -> %{phase: :building, done: 0, total: get(f, :n), file: nil, at: now}
      :file -> %{phase: :building, done: get(f, :i) + 1, total: get(f, :n), file: f[:file], at: now}
      _ -> Map.put(f, :at, now)
    end
  end

  defp get(f, k), do: Map.get(f, k) || 0

  # The other half of "total on purpose": a frame that is not a beam-lisp map is
  # not a frame at all — a Vector or a Set is an Erlang map carrying `:__struct__`,
  # and storing one would put a struct in the table the dashboard renders from.
  # `code.index` builds the frame on line 309 and passes a map; anything else is
  # a caller's mistake, and the build must not fail for the UI's sake.
  def progress!(_), do: :ok

  @doc """
  Index the tree now, in the background. Idempotent in the only sense that
  matters: a build that arrives while one is running waits its turn and then
  HITS (the bytes have not moved), so the cost of asking too often is zero.

  The daemon calls this at boot, so the first question usually finds the index
  warm; `bl ui` calls it too, so a session started before the tree changed can be
  brought up to date without a question being asked first.
  """
  def ensure_building(server \\ __MODULE__) do
    GenServer.cast(server, :build)
  end

  @doc "The index this worker built, or nil: `{:conn :key :stats …}` (beam-lisp)."
  def built(server \\ __MODULE__) do
    GenServer.call(server, :built)
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ets.insert(@table, {:progress, cold()})

    # A build at BOOT, not on the first question: the point of a warm session is
    # that the work happened before anyone asked. Deferred through the mailbox so
    # `init` stays instant and the daemon's listener is bound before the tree is
    # read — the build then runs in this worker, where nobody is waiting.
    #
    # `build: false` is for a caller that owns this worker for one assertion (a
    # test): starting a supervisor must not index a real tree behind its back.
    if Keyword.get(opts, :build, true), do: send(self(), :build)

    {:ok, %{root: Keyword.get(opts, :root) || File.cwd!(), built: nil}}
  end

  @impl true
  def handle_cast(:build, state) do
    send(self(), :build)
    {:noreply, state}
  end

  @impl true
  def handle_info(:build, state) do
    {:noreply, %{state | built: do_build(state.root)}}
  end

  @impl true
  def handle_call({:run, fun}, _from, state), do: {:reply, fun.(), state}
  def handle_call(:built, _from, state), do: {:reply, state.built, state}

  # --- the build ---

  defp do_build(root) do
    report(%{phase: :building, done: 0, total: 0, file: nil})

    try do
      BeamLisp.Loader.ensure_loaded("code.index")

      BeamLisp.RT.invoke(
        BeamLisp.Env.fetch!("code.index", "ensure-tree"),
        [root]
      )
    rescue
      e ->
        report(%{phase: :error, message: Exception.message(e), done: 0, total: 0, file: nil})
        nil
    catch
      kind, reason ->
        msg = "#{kind}: #{inspect(reason)}"
        report(%{phase: :error, message: msg, done: 0, total: 0, file: nil})
        nil
    end
  end

  defp report(frame), do: progress!(frame)
end
