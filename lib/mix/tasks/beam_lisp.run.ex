defmodule Mix.Tasks.BeamLisp.Run do
  @moduledoc """
  Run a beam-lisp file: `mix beam_lisp.run examples/hello.bl`

  `--path DIR` adds a library root to the loader's search path (repeatable);
  `BEAM_LISP_PATH` (colon-separated) does the same from the environment. The
  entry file's own directory is always searched, so a self-contained program
  needs neither.

  `--code-path DIR` puts a directory of AOT beams (`mix beam_lisp.aot --out DIR`)
  on the VM's code path (repeatable); `BEAM_LISP_CODE_PATH` (colon-separated)
  does the same from the environment. This is NOT `ERL_AFLAGS="-pa DIR"`: Mix
  prunes the code path down to the project's deps once it has loaded the
  project (`prune_code_paths`, default on since 1.15), so a `-pa` given to the
  VM is gone by the time the program runs — silently, and the loader falls
  back to compiling every namespace from source. The flag adds the directory
  AFTER the prune, where it sticks.
  """
  @shortdoc "Run a beam-lisp file"

  use Mix.Task

  # Frames from these modules describe *beam-lisp's* execution, not the
  # user's program. A failing `.bl` file used to bury its own frame under
  # eval_string/with_load_path/Enum.map noise; now the source frames come
  # first and the machinery is summarised. Nothing is swallowed — the
  # error, its message and a count of the hidden frames all still print.
  @internal_modules [
    BeamLisp.Compiler,
    BeamLisp.Loader,
    BeamLisp.Link,
    BeamLisp.Env,
    Mix.Tasks.BeamLisp.Run,
    Mix.Task
  ]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, args} =
      OptionParser.parse!(argv, strict: [path: :keep, code_path: :keep], aliases: [p: :path])

    for {:path, dir} <- opts, do: BeamLisp.Env.add_search_path(dir)
    for dir <- code_paths(opts), do: Code.prepend_path(Path.expand(dir))

    case args do
      [path] -> run_file(path)
      _ -> Mix.raise("usage: mix beam_lisp.run [--path DIR] FILE.bl")
    end
  end

  @doc false
  def code_paths(opts) do
    env =
      case System.get_env("BEAM_LISP_CODE_PATH") do
        nil -> []
        "" -> []
        s -> String.split(s, ":", trim: true)
      end

    for({:code_path, dir} <- opts, do: dir) ++ env
  end

  defp run_file(path) do
    try do
      path |> BeamLisp.run_file() |> BeamLisp.RT.print_str() |> IO.puts()
    catch
      kind, reason ->
        # `catch` covers throws as well as raises, because beam-lisp's
        # `throw` is a real BEAM throw and a user can reach the top level
        # with one.
        IO.puts(:stderr, format(kind, reason, __STACKTRACE__))
        exit({:shutdown, 1})
    end
  end

  defp format(kind, reason, stacktrace) do
    {source, internal} = Enum.split_while(stacktrace, &source_frame?/1)

    case source do
      # Nothing user-facing to lead with — print the trace unabridged
      # rather than an empty one.
      [] ->
        Exception.format(kind, reason, stacktrace)

      _ ->
        banner = Exception.format_banner(kind, reason, stacktrace)
        body = Enum.map_join(source, "\n", &("    " <> Exception.format_stacktrace_entry(&1)))

        trailer =
          case internal do
            [] -> ""
            frames -> "\n    … #{length(frames)} frames in beam-lisp internals"
          end

        banner <> "\n" <> body <> trailer
    end
  end

  # A frame belongs to the user's program if it is not one of ours. `.bl`
  # frames now carry a real source file, so they read like any other
  # language's trace.
  defp source_frame?({mod, _fun, _arity, _loc}) do
    mod not in @internal_modules and not elixir_internal?(mod)
  end

  defp source_frame?(_), do: false

  defp elixir_internal?(mod) do
    name = Atom.to_string(mod)
    String.starts_with?(name, "Elixir.Enum") or String.starts_with?(name, "Elixir.Stream")
  end
end
