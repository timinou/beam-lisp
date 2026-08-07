defmodule BeamLisp.Loader do
  @moduledoc """
  Loads namespaces from files on first require.

  `(ns app (:require [geometry]))` compiles to a call to
  `ensure_loaded/1`, which searches the load paths for
  `geometry.bl` (dots become directory separators) and evaluates it
  under its own namespace. Namespaces load once; re-requiring is a
  no-op. `core` is always considered loaded — `BeamLisp.init/0`
  seeds it.

  The load path is a stack: `BeamLisp.run_file/1` pushes the file's
  directory, so a program can require siblings next to its entry
  point, and pops it afterwards.
  """

  alias BeamLisp.{Compiler, Env}

  @doc "Evaluate `path` with its directory on the load path, then pop it."
  def with_load_path(dir, fun) do
    Env.push_load_path(dir)

    try do
      fun.()
    after
      Env.pop_load_path()
    end
  end

  @doc "Load `ns` from `<ns>.bl` on the load paths, unless already loaded."
  def ensure_loaded(ns) when is_binary(ns) do
    if ns == "core" or Env.loaded_ns?(ns) or Env.ns_exists?(ns) do
      :ok
    else
      case find_file(ns) do
        nil ->
          raise "namespace not found: #{ns} (searched: #{inspect(search_dirs())})"

        path ->
          Env.mark_loaded(ns)
          prev_ns = Env.current_ns()

          try do
            with_load_path(Path.dirname(path), fn ->
              path |> File.read!() |> Compiler.eval_string(Compiler.new_env(ns), path)
            end)
          after
            # A required file's (ns …) is scoped to that file; the
            # requiring namespace must survive the load.
            Env.in_ns(prev_ns)
          end

          :ok
      end
    end
  end

  defp find_file(ns) do
    rel = String.replace(ns, ".", "/") <> ".bl"
    Enum.find_value(search_dirs(), fn dir ->
      path = Path.join(dir, rel)
      if File.regular?(path), do: path
    end)
  end

  # priv/ ships beam-lisp's own libraries (optics, rewrite, …). They are
  # not part of the prelude — you pay for them only by requiring them —
  # but they must be findable without the user knowing where the
  # application was installed, so priv comes last: a project file of the
  # same name still wins.
  defp search_dirs do
    Env.load_paths() ++ [File.cwd!(), Application.app_dir(:beam_lisp, "priv")]
  end
end
