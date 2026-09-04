defmodule BeamLisp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = dev_port()

    children =
      [BeamLisp.Env, BeamLisp.Loader.Server] ++
        if dev_server?() and port_free?(port) do
          # Tidewave MCP endpoint: http://127.0.0.1:9837/tidewave/mcp
          # BEAMLISP_DEV_PORT overrides the port — test/CI harnesses set a
          # random high port so parallel one-shot runs never collide.
          [{Bandit, plug: BeamLisp.DevServer, port: port, ip: {127, 0, 0, 1}}]
        else
          []
        end

    result = Supervisor.start_link(children, strategy: :one_for_one, name: BeamLisp.Supervisor)

    # Boot the language now that Env + Loader.Server are supervised. Since the
    # Elixir genesis compiler/reader were deleted, the reader/compiler facades
    # (BeamLisp.Reader.read_one/1 etc.) run the self-hosted `.bl` toolchain,
    # which resolves its sibling vars (e.g. `reader/unwrap-deep`) through the Env
    # var table — so those namespaces MUST be interned before first use. Genesis
    # used to make these entry points work with no boot; now `init/0` (idempotent,
    # guarded by `Env.seeded?/0`) interns the toolchain from the committed seed.
    # An embedded/one-shot runtime that starts the app then calls the language
    # therefore Just Works, exactly as it did when genesis was the floor.
    BeamLisp.init()

    result
  end

  # A listener whose port is already held is SKIPPED rather than fatal.
  #
  # The endpoint here is a convenience: an already-running session owns the
  # port, and a second `mix run -e '…'` must still be able to evaluate
  # something. Before this, any such command died with `:eaddrinuse` from a
  # supervisor three levels down — a message about the wrong subsystem
  # entirely, produced while the user was debugging something else.
  #
  # NB this is a check, not a reservation: a race between check and listen is
  # possible and still fails loudly. The point is that the COMMON case (a
  # session is already serving) stops being an unrelated crash.
  defp dev_port do
    case System.get_env("BEAMLISP_DEV_PORT") do
      nil ->
        9837

      s ->
        case Integer.parse(s) do
          {p, ""} when p > 0 and p < 65_536 -> p
          _ -> 9837
        end
    end
  end

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
