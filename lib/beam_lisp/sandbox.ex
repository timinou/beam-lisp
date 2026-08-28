defmodule BeamLisp.Sandbox do
  @moduledoc """
  The test-harness surface for beam-lisp envs (PLAN-046 L3).

  A BASE IMAGE is an env holding evaluated namespaces. `:global` always
  exists (the prelude); `warm!/2` creates a named base holding whatever
  an app's tests need, once per VM. `checkout/1` forks a child of a base
  and binds it in the calling process — µs-cheap, zero-copy, because
  reads fall through to the base and writes stay local. `checkin/1`
  destroys the fork.

      # once per VM (usually via `use BeamLisp.ExUnitCase`):
      Sandbox.warm!(:my_app, ["my.app", "my.app.more"])

      # per test, async: true:
      env = Sandbox.checkout(:my_app)   # warm fork
      ... test body, fully isolated ...
      Sandbox.checkin(env)

  Warm vs cold is a one-token choice:

    * WARM — `checkout(:my_app)`: sees every var the base loaded;
      for unit tests over loaded namespaces.
    * COLD — `checkout()` (parent `:global`, prelude only) then
      `load_file/1` / `load_ns/1` / `eval/1`: re-evals exactly what the
      test names; with the AOT cache (FEAT-002) a cold load of compiled
      namespaces is milliseconds.

  Nothing here changes `:global` behavior: an app that never checks out
  an env runs exactly as before.
  """

  alias BeamLisp.{Compiler, Env, Loader}

  @doc """
  Evaluate `sources` into a fresh base env named `name`, once per VM.

  `sources` are namespace names (`"my.app"` — loaded through the loader,
  honoring search paths) or file paths (anything that exists on disk —
  evaluated like a test file, with its directory pushed as a load path).

  Idempotent by `name`: a second call returns the existing base. A
  concurrent double-warm does the work twice and leaks one base's rows —
  wasteful, never wrong.
  """
  def warm!(name, sources) when is_atom(name) and is_list(sources) do
    case :persistent_term.get({__MODULE__, name}, :undefined) do
      :undefined ->
        BeamLisp.init()
        base = Env.fork(:global)

        Env.with_env(base, fn ->
          Enum.each(sources, &load_source/1)
        end)

        :persistent_term.put({__MODULE__, name}, base)
        base

      base ->
        base
    end
  end

  @doc "The base env previously warmed under `name`; raises if absent."
  def base!(name) when is_atom(name) do
    case :persistent_term.get({__MODULE__, name}, :undefined) do
      :undefined ->
        raise "no warm base #{inspect(name)} — warm it with BeamLisp.Sandbox.warm!/2 first"

      base ->
        base
    end
  end

  @doc """
  Fork a child of `base` (an env id, a warmed name, or `:global`) and bind
  it in the CALLING process. Returns the env id for `checkin/1`.
  """
  def checkout(base \\ :global)

  def checkout(base) when is_atom(base) and base != :global do
    checkout(base!(base))
  end

  def checkout(base) do
    env = Env.fork(base)
    Env.attach(env)
    env
  end

  @doc "Destroy a checked-out env. Call from `on_exit`."
  def checkin(env), do: Env.destroy(env)

  @doc "Evaluate a file into the current env (its directory becomes a load path)."
  def load_file(path) do
    Loader.with_load_path(Path.dirname(path), fn ->
      Compiler.eval_string(File.read!(path))
    end)

    :ok
  end

  @doc "Load a namespace into the current env through the loader."
  def load_ns(ns) when is_binary(ns) do
    Loader.ensure_loaded(ns)
    :ok
  end

  @doc "Evaluate a string of source into the current env."
  def eval(source) when is_binary(source) do
    Compiler.eval_string(source)
    :ok
  end

  defp load_source(source) do
    if File.exists?(source), do: load_file(source), else: load_ns(source)
  end
end
