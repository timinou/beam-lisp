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

  A file's namespace is *declared* by its leading `(ns …)` form, not
  implied by its basename. Two files can share a name — an example and
  the library it demos both called `optics` — but only the file that
  actually declares the requested ns may serve that require, so a
  same-named file can never hijack one. `find_file/1` reads each
  candidate's `(ns …)` head and skips a candidate whose declared ns
  does not match; the search still stops at the first directory whose
  file owns the ns, so a project-local override shadows `priv/`.
  """

  alias BeamLisp.{Compiler, Env}

  # Characters that end a symbol token — whitespace, commas, delimiters,
  # quote/reader-macro prefixes. An ns name is a plain dotted symbol, so
  # scanning to the first such character yields it without parsing the
  # rest of the file.
  @token_end ~c"()[]{}\",;'`@#~"
  @ws ~c" \t\n\r,"

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
    if ns == "core" or Env.loaded_ns?(ns) do
      :ok
    else
      case find_file(ns) do
        {:ok, path, content} ->
          Env.mark_loaded(ns)
          prev_ns = Env.current_ns()

          try do
            with_load_path(Path.dirname(path), fn ->
              Compiler.eval_string(content, Compiler.new_env(ns), path)
            end)
          after
            # A required file's (ns …) is scoped to that file; the
            # requiring namespace must survive the load.
            Env.in_ns(prev_ns)
          end

          :ok

        {:wrong_ns, path, nil} ->
          raise "namespace #{ns}: #{path} exists but declares no (ns …) form " <>
                  "(a file's namespace comes from its (ns …), not its name) " <>
                  "(searched: #{inspect(search_dirs())})"

        {:wrong_ns, path, declared} ->
          raise "namespace #{ns}: #{path} declares (ns #{declared}), not #{ns} " <>
                  "(a same-named file cannot serve another namespace) " <>
                  "(searched: #{inspect(search_dirs())})"

        # No file — but a namespace does not have to come from one. It
        # may already exist because an earlier form in this same source
        # declared it, or the REPL built it live. Requiring it is then a
        # no-op rather than an error: the vars it aliases are already in
        # the registry. Only a namespace that exists nowhere is a
        # genuine miss, and that is the one worth a search-path report.
        nil ->
          if Env.ns_exists?(ns) do
            :ok
          else
            raise "namespace not found: #{ns} (searched: #{inspect(search_dirs())})"
          end
      end
    end
  end

  # Search the load paths for a regular `<ns>.bl` whose declared ns
  # matches. Returns {:ok, path, content} for the first matching file;
  # else the first same-named file whose declared ns differs (so the
  # error can name both); else nil when no file exists at all. A
  # candidate whose declared ns does not match is skipped, not loaded —
  # so a project-local file that really owns the ns still shadows
  # priv/, while an example that merely shares the name cannot hijack
  # the require. The matching file's content is returned to avoid
  # reading it twice: once for the ns check, once for the load.
  defp find_file(ns) do
    rel = String.replace(ns, ".", "/") <> ".bl"

    Enum.reduce(search_dirs(), nil, fn dir, acc ->
      case acc do
        {:ok, _, _} ->
          acc

        _ ->
          path = Path.join(dir, rel)

          if File.regular?(path) do
            content = File.read!(path)

            case declared_ns(content) do
              ^ns -> {:ok, path, content}
              other -> acc || {:wrong_ns, path, other}
            end
          else
            acc
          end
      end
    end)
  end

  # The namespace a file declares: the first symbol after its leading
  # `(ns …)`. Leading whitespace and `;` comments are skipped; a file
  # whose first form is not `(ns …)` declares no namespace and returns
  # nil. Only the head is consumed — the scan stops at the end of the
  # ns name, and the file's body is left for the eventual load to parse.
  defp declared_ns(source) do
    case skip_leading(source) do
      "(" <> rest ->
        rest = skip_leading(rest)

        case take_token(rest) do
          {"ns", rest} ->
            rest = skip_leading(rest)

            case take_token(rest) do
              {name, _} -> name
              nil -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp skip_leading(<<c, rest::binary>>) when c in @ws, do: skip_leading(rest)

  defp skip_leading(";" <> rest) do
    case :binary.split(rest, "\n") do
      [_, tail] -> skip_leading(tail)
      [_] -> ""
    end
  end

  defp skip_leading(other), do: other

  # The next symbol token and the tail after it; nil when the head is
  # whitespace, a delimiter, or empty.
  defp take_token(<<c, _::binary>>) when c in @token_end or c in @ws, do: nil
  defp take_token(<<>>), do: nil
  defp take_token(s), do: split_token(s, [])

  defp split_token(<<c, rest::binary>>, acc) when c in @token_end or c in @ws,
    do: {acc |> Enum.reverse() |> to_string, <<c, rest::binary>>}

  defp split_token(<<c, rest::binary>>, acc), do: split_token(rest, [c | acc])
  defp split_token(<<>>, acc), do: {acc |> Enum.reverse() |> to_string, ""}

  # priv/ ships beam-lisp's own libraries (optics, rewrite, …). They are
  # not part of the prelude — you pay for them only by requiring them —
  # but they must be findable without the user knowing where the
  # application was installed, so priv comes last: a project file of the
  # same name still wins.
  defp search_dirs do
    Env.load_paths() ++ [File.cwd!(), Application.app_dir(:beam_lisp, "priv")]
  end
end
