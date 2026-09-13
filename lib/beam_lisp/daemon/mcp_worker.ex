defmodule BeamLisp.Daemon.McpWorker do
  @moduledoc """
  Owns the HTTP MCP server's index-mount lifetime.

  ## Why this module exists

  The daemon serves `POST /mcp` with the SAME MCP server `bl mcp` serves over
  stdio (`mcp.server/request-response`). That server memoizes the tree's
  codebase index — a datom conn whose store is ETS tables — behind a
  `datom/alive?` check, so a mount is built once and then reused.

  "Once" only holds while the tables live, and ETS tables are owned by the
  process that created them. The CLI path mounts inside the long-lived
  Executor worker, so a second `bl ask` reuses the memo and answers in
  seconds. The HTTP path invoked `request-response` in the PER-REQUEST
  connection process: request 1 mounted the tree (~90 s on a real tree),
  answered, the process exited, the tables died, and request 2 paid the full
  mount again — every HTTP code question, forever. Measured: two identical
  `code/ask` POSTs back-to-back took 79 s then 95 s, while the same question
  through the warm CLI took 3 s.

  The fix is ownership, not caching: every `/mcp` request now runs on THIS
  worker — one long-lived GenServer next to the Executor — so the mount's
  tables outlive any request and the memo the server already had starts doing
  its job. A worker crash restarts it (see `BeamLisp.Daemon.Workers`) and the
  next request simply re-mounts: the memo's `alive?` check was built for
  exactly that.

  Requests serialize on the worker, which is the honest shape of the
  resource: there is one mount and one mount owner, and MCP traffic is one
  agent session asking one question at a time.
  """

  use GenServer

  # --- public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Run `fun` on the mount-owning process and hand back its result.

  The whole contract is WHERE the function runs: anything the function builds
  (a datom conn, its ETS tables) is owned by this worker and therefore
  survives the caller. No timeout: a first request on a cold tree pays the
  index mount, which is minutes on a large tree.
  """
  def run(fun, server \\ __MODULE__) when is_function(fun, 0) do
    GenServer.call(server, {:run, fun}, :infinity)
  end

  # --- GenServer ---

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:run, fun}, _from, state) do
    {:reply, fun.(), state}
  end
end
