defmodule BeamLisp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [BeamLisp.Env] ++
        if dev_server?() do
          # Tidewave MCP endpoint: http://127.0.0.1:9837/tidewave/mcp
          [{Bandit, plug: BeamLisp.DevServer, port: 9837, ip: {127, 0, 0, 1}}]
        else
          []
        end

    Supervisor.start_link(children, strategy: :one_for_one, name: BeamLisp.Supervisor)
  end

  # The Tidewave endpoint is for interactive sessions (iex -S mix,
  # mix run --no-halt), never for one-shot CLI tasks — a
  # `mix beam_lisp.run file.bl` or `mix run -e …` must not fight a
  # running playground for port 9837.
  defp dev_server? do
    Mix.env() == :dev and not cli_task?()
  end

  defp cli_task? do
    case System.argv() do
      # iex -S mix arrives with no task argument.
      [] -> false
      # mix run is only interactive when it stays up.
      ["run" | args] -> "--no-halt" not in args
      [_task | _] -> true
    end
  end
end
