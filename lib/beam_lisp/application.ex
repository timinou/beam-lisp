defmodule BeamLisp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [BeamLisp.Env] ++
        if dev_server?() and port_free?(9837) do
          # Tidewave MCP endpoint: http://127.0.0.1:9837/tidewave/mcp
          [{Bandit, plug: BeamLisp.DevServer, port: 9837, ip: {127, 0, 0, 1}}]
        else
          []
        end ++
        if spell_serve?() and port_free?(verse_port()) do
          # The verse dev server: the warm compiler the FS protocol
          # (`Spell.Build`) talks to. Port-gated like the other listeners: a
          # second session finding 4444 held talks to the FIRST session's
          # serve — the same kindness, and the same lie if the site dirs
          # differ, which serve_live.exs' startup report must surface.
          # `:ignore`d when no binary exists.
          [BeamLisp.Spell.Serve]
        else
          []
        end ++
        if spell_endpoint?() and port_free?(spell_port()) do
          # The seam's server half. PubSub first: Phoenix.Endpoint reads
          # `pubsub_server` from config and a LiveView that outlives its
          # process group would find nothing to (re)join.
          [{Phoenix.PubSub, name: SpellWeb.PubSub}, SpellWeb.Endpoint]
        else
          []
        end

    Supervisor.start_link(children, strategy: :one_for_one, name: BeamLisp.Supervisor)
  end

  # A listener whose port is already held is SKIPPED rather than fatal.
  #
  # Both endpoints here are conveniences: an already-running session owns the
  # port, and a second `mix run -e '…'` must still be able to evaluate
  # something. Before this, any such command died with `:eaddrinuse` from a
  # supervisor three levels down — a message about the wrong subsystem
  # entirely, produced while the user was debugging something else.
  #
  # NB this is a check, not a reservation: a race between check and listen is
  # possible and still fails loudly. The point is that the COMMON case (a
  # session is already serving) stops being an unrelated crash.
  defp port_free?(port) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, :eaddrinuse} ->
        require Logger
        Logger.info("port #{port} is already held — skipping that listener")
        false

      {:error, _other} ->
        true
    end
  end

  defp spell_port do
    case Application.get_env(:beam_lisp, SpellWeb.Endpoint) do
      nil -> 4030
      cfg -> get_in(cfg, [:http, :port]) || 4030
    end
  end

  defp verse_port, do: Application.get_env(:beam_lisp, :spell_verse_port, 4444)

  # The verse dev server is a LIVE-RELOAD tool, so it starts only in live mode.
  #
  # Tests are `async: false` across the spell suites, so one serve on one site
  # dir is one writer at a time.
  #
  # It used to start alongside the endpoint, which made a dev server part of
  # booting an application: the app spawned its own `spacetime serve`, the page
  # was published to it at runtime, and the browser fetched the bundle from a
  # second origin. A page that is a deterministic artifact of its terms has no
  # business being compiled at boot — it is built ahead of time and served from
  # `priv/static` like any other asset.
  #
  # `mix test` keeps it: the publish tests exercise the FS protocol itself, and
  # that protocol is exactly what needs a warm compiler to talk to.
  defp spell_serve? do
    Code.ensure_loaded?(Mix) and
      (Mix.env() == :test or (BeamLisp.Spell.Build.live?() and spell_endpoint?()))
  end

  # The chat endpoint runs for interactive sessions only, and by the same rule
  # as the Tidewave one: a `mix test` run or a one-shot `mix run script.exs`
  # must not bind port 4000 out from under a session that is serving the page.
  # `mix run --no-halt scripts/serve_live.exs` IS interactive by that rule,
  # which is what makes it the command that serves spell.
  defp spell_endpoint? do
    Code.ensure_loaded?(Mix) and Mix.env() == :dev and not cli_task?()
  end

  # The Tidewave endpoint is for interactive sessions (iex -S mix,
  # mix run --no-halt), never for one-shot CLI tasks — a
  # `mix beam_lisp.run file.bl` or `mix run -e …` must not fight a
  # running playground for port 9837.
  # The DevServer module only exists when compiled in beam-lisp's own :dev
  # (lib/dev is excluded from other elixirc_paths, so dependents never see it);
  # Mix itself may be absent on embedded runtimes (Mob deploys app beams only).
  defp dev_server? do
    Code.ensure_loaded?(BeamLisp.DevServer) and Code.ensure_loaded?(Mix) and
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
