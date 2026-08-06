# Dev-only: Tidewave/Plug exist only in :dev deps, so compile the
# module only when they are loadable (mix.exs also gates lib/dev via
# elixirc_paths, belt and suspenders).
if Code.ensure_loaded?(Plug.Conn) do
  defmodule BeamLisp.DevServer do
  @moduledoc """
  Dev-only HTTP endpoint. Its whole job is hosting Tidewave's MCP
  tools (`project_eval`, docs, source lookup) against the running
  beam-lisp app, so agents can drive the language live:

      iex -S mix   # or: mix run --no-halt
      # MCP endpoint: http://127.0.0.1:9837/tidewave/mcp

  The port is deliberately uncommon and bound to loopback. Only
  `/tidewave` paths are delegated — Tidewave.call matches
  `["tidewave" | rest]` on the unstripped path and forwards
  internally.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["tidewave" | _]} = conn, _opts) do
    Tidewave.call(conn, Tidewave.init([]))
  end

  def call(conn, _opts) do
    send_resp(conn, 404, "beam-lisp dev server: only /tidewave is served\n")
  end
end

end
