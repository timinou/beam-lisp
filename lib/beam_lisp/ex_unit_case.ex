defmodule BeamLisp.ExUnitCase do
  @moduledoc """
  One-line async tests for beam-lisp apps (PLAN-046 L3).

      defmodule MyAppTest do
        use BeamLisp.ExUnitCase, warm: {:my_app, ["my.app", "my.app.more"]}

        test "does the thing" do
          # runs in a private fork of the :my_app base image;
          # async: true is on, and nothing here can touch another test
        end
      end

  Options:

    * `warm: {name, sources}` — a base image (see `BeamLisp.Sandbox.warm!/2`)
      every test forks from. Sources are namespace names or file paths.
    * `warm: name` — reuse a base already warmed elsewhere (raises in
      `setup_all` if missing).
    * no `warm` — each test forks `:global` (the prelude only); load what
      the test needs with `BeamLisp.Sandbox.load_ns/1`, `load_file/1`, or
      `eval/1`. This is the COLD shape.
    * `async: false` — opt out for tests that touch the documented-global
      registries (`BeamLisp.Record`, `BeamLisp.Native`, `BeamLisp.LazySeq`).

  Every test gets a fresh env fork (`:bl_env` in the test context), checked
  in automatically `on_exit`. Warm bases are created once per VM, so a whole
  tree of `use`d modules pays the load once.
  """

  @doc false
  def resolve_base(nil), do: :global
  def resolve_base(name) when is_atom(name), do: BeamLisp.Sandbox.base!(name)
  def resolve_base({name, sources}), do: BeamLisp.Sandbox.warm!(name, sources)

  defmacro __using__(opts) do
    warm = Keyword.get(opts, :warm)
    async? = Keyword.get(opts, :async, true)

    quote do
      use ExUnit.Case, async: unquote(async?)

      setup_all do
        BeamLisp.init()
        {:ok, bl_base: BeamLisp.ExUnitCase.resolve_base(unquote(warm))}
      end

      setup %{bl_base: bl_base} do
        env = BeamLisp.Sandbox.checkout(bl_base)
        on_exit(fn -> BeamLisp.Sandbox.checkin(env) end)
        {:ok, bl_env: env}
      end
    end
  end
end
