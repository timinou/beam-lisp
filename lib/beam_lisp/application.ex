defmodule BeamLisp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [BeamLisp.Env, BeamLisp.Loader.Server]

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
end
