defmodule BeamLisp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BeamLisp.Env
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BeamLisp.Supervisor)
  end
end
