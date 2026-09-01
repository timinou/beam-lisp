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
  @doc """
  The provenance hash of `ns`'s source `.bl` on the current search path, or
  `nil` when no source is findable (a prod release ships beams, not sources).

  Byte-identical to the AOT stamp (`__bl_provenance__/0`) and the Mix manifest:
  `sha256(content) |> Base.encode16()`. Used by the drift-aware AOT load gate to
  decide whether a compiled beam still matches the source it was built from.
  Runs inside `Loader.Server` (where `find_file/1`'s search dirs resolve), the
  same context `AOT.ensure_loaded/1` is called from.
  """
  def source_hash(ns) when is_binary(ns) do
    case find_file(ns) do
      {:ok, _path, content} -> :crypto.hash(:sha256, content) |> Base.encode16()
      _ -> nil
    end
  end

  @doc """
  Run `fun` with `dir` pinned as the sole ambient search directory, so
  `find_file/1` / `source_hash/1` / `AOT.ensure_loaded/1` resolve `.bl` sources
  from there. Restores the prior binding after. Used by the drift gate's tests
  and any caller that must resolve a namespace against a known directory rather
  than the process's ambient roots.
  """
  def with_search_dir(dir, fun) do
    prev = Process.get(:bl_search_dirs)
    Process.put(:bl_search_dirs, [dir])

    try do
      fun.()
    after
      if is_nil(prev),
        do: Process.delete(:bl_search_dirs),
        else: Process.put(:bl_search_dirs, prev)
    end
  end

  @doc "`source_hash/1` for `ns` resolved against `dir` alone."
  def source_hash_in(dir, ns) do
    with_search_dir(dir, fn -> source_hash(ns) end)
  end
  @doc "Load `ns` from `<ns>.bl` on the load paths, unless already loaded."
  def ensure_loaded(ns) when is_binary(ns) do
    # AOT FIRST, and this is the one place it can go.
    #
    # `mix compile.beam_lisp` emits each namespace as a real BEAM module, and
    # loading one from disk costs nothing next to reading and compiling its
    # source. Putting the preference HERE rather than in each caller is what
    # makes it reach TRANSITIVE requires: `(:require [datom])` comes back
    # through this function, so a project that never mentions `datom.tx` still
    # gets the compiled one.
    #
    # Measured, loading `datom` (seventeen files) in a fresh VM:
    #
    #     via AOT      14.7s
    #     via source   3m20s+ (timed out)
    #
    # That is not a nicety at the top of a scale — it was the difference
    # between a durability test that spawns two child VMs and one that times
    # out, and it was paid by every `mix run` of every script downstream.
    #
    # `AOT.ensure_loaded/1` returns `:no_module` when nothing is on the code
    # path, so an uncompiled checkout still works through the branch below —
    # slowly, and correctly. On `:loaded` it marks the namespace, so the
    # `loaded_ns?` guard immediately below short-circuits and the source is
    # never read.
    loading = Process.get(:bl_loading, MapSet.new())

    cond do
      ns == "core" or Env.loaded_ns?(ns) ->
        :ok

      # A require CYCLE coming back around (A requires B requires A):
      # A is in-progress ON THIS PROCESS CHAIN. Cut it — the cyclic
      # reference resolves at call time, after both loads finish. This
      # replaces mark-first, whose window a CONCURRENT require could see:
      # marked-loaded but vars not yet interned (relay.sse/to-sse-stream
      # undefined under BL_ASYNC=1).
      MapSet.member?(loading, ns) ->
        :ok

      true ->
        # All library loads run in the pinned Loader.Server process:
        # load-time process-owned state (ETS tables!) must outlive the
        # requiring process, and a single loader process makes the per-path
        # trans locks below self-serialized — never contended across
        # processes, so no lock-order inversion. Nested requires detect the
        # server via its pdict flag and run inline.
        #
        # The AMBIENT search dirs (cwd + configured paths) are captured
        # HERE, in the caller: Env.search_paths/0 resolves through the
        # caller's env chain (a warm base, a test fork), and that binding
        # does not survive the hop into the server process — a sandboxed
        # caller whose roots live in its own env would otherwise load
        # against :global's paths alone and miss namespaces its own env
        # can see (Sandbox.warm! adds cwd/src to the BASE env — exactly
        # this case). The per-load load-path stack is NOT captured: it
        # belongs to whatever load is in progress and reads correctly
        # inside the server.
        dirs = [File.cwd!()] ++ extra_dirs()

        BeamLisp.Loader.Server.run(fn ->
          prev = Process.get(:bl_search_dirs)
          Process.put(:bl_search_dirs, dirs)

          try do
            ensure_loaded_locked(ns)
          after
            if is_nil(prev),
              do: Process.delete(:bl_search_dirs),
              else: Process.put(:bl_search_dirs, prev)
          end
        end)
    end
  end

  defp ensure_loaded_locked(ns) do
    if ns == "core" or Env.loaded_ns?(ns) or
         MapSet.member?(Process.get(:bl_loading, MapSet.new()), ns) do
      :ok
    else
      Process.put(:bl_loading, MapSet.put(Process.get(:bl_loading, MapSet.new()), ns))

      try do
        case BeamLisp.AOT.ensure_loaded(ns) do
          :loaded ->
            :ok

          :no_module ->
            ensure_loaded_source(ns)
        end
      after
        Process.put(:bl_loading, MapSet.delete(Process.get(:bl_loading), ns))
      end
    end
  end

  defp ensure_loaded_source(ns) do
    if Env.loaded_ns?(ns) do
      :ok
    else
      # One loader per FILE VM-wide: two forked envs requiring the same
      # namespace CONCURRENTLY would otherwise both compile it —
      # Module.create("currently being defined") races plus double eval.
      # Keyed on the resolved PATH, not the ns: a multi-namespace file
      # (usage.bl defining relay.error forms inline) raced a concurrent
      # require of error.bl under ns-keyed locks — different locks, same
      # module, boom. find_file runs BEFORE the lock (its cost is a
      # read); the loser re-checks `loaded_ns?` inside and short-circuits.
      # Lock ids are {resource, requester} 2-tuples (:global.trans).
      case find_file(ns) do
        {:ok, path, content} ->
          :global.trans({{:bl_load, path}, self()}, fn ->
            if Env.loaded_ns?(ns), do: :ok, else: do_load(ns, path, content)
          end)

        other ->
          do_load_miss(ns, other)
      end
    end
  end

  # do_load is the REQUIRE path — a namespace another namespace depends
  # on, i.e. LIBRARY code. Libraries load at `:global`: one shared copy
  # every env reads through its chain, like core and the prelude. Loading
  # a library into the requiring env instead gave each async test fork
  # its own private datom/auth/relay.* namespaces: compiled fn modules
  # are VM-global but the var registry entries were per-env, so a process
  # bound to fork F1 missed vars interned under F2 (PLAN-047 W1:
  # "undefined var: env/convey" in the datom conn registry Agent;
  # "undefined var: relay.ratelimit/WINDOW-SECONDS" in relay's singletons
  # under BL_ASYNC=1).
  #
  # Clojure's model, exactly: libraries are global, YOUR namespaces are
  # yours. Isolation is untouched where it matters — the test file itself
  # is EVALUATED (not required) into its fork, so its defs, its tests,
  # and its shadows (a fork-local `(ns relay.ratelimit) (defn …)` beats
  # the global var on that fork's chain) stay private.
  defp do_load(ns, path, content) do
    prev_ns = Env.current_ns()

    try do
      with_load_path(Path.dirname(path), fn ->
        Env.with_env(:global, fn ->
          Compiler.eval_string(content, Compiler.new_env(ns), path)
          # Mark AFTER the eval: marking first opened a window where a
          # concurrent require saw "loaded" with no vars interned. Cycle
          # safety is the :bl_loading set in ensure_loaded_locked/1, not
          # the mark. A crashed load is retried by the next require.
          Env.mark_loaded(ns)
        end)
      end)
    after
      # A required file's (ns …) is scoped to that file; the
      # requiring namespace must survive the load.
      Env.in_ns(prev_ns)
    end

    :ok
  end

  defp do_load_miss(ns, miss) do
    case miss do
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

  @doc_extensions [".bl", ".bl.md", ".bl.org"]

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
    base = String.replace(ns, ".", "/")

    Enum.reduce(search_dirs(), nil, fn dir, acc ->
      case acc do
        {:ok, _, _} ->
          acc

        _ ->
          Enum.reduce(@doc_extensions, acc, fn ext, acc ->
            case acc do
              {:ok, _, _} ->
                acc

              _ ->
                path = Path.join(dir, base <> ext)

                if File.regular?(path) do
                  raw = File.read!(path)
                  content = doc_content(path, raw)

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
    end)
  end

  # The namespace a file declares: the first symbol after its leading
  # `(ns …)`. Leading whitespace and `;` comments are skipped; a file
  # whose first form is not `(ns …)` declares no namespace and returns
  # nil. Only the head is consumed — the scan stops at the end of the
  # ns name, and the file's body is left for the eventual load to parse.
  # A document's loadable source: itself when plain .bl, else its code cells.
  defp doc_content(path, raw) do
    if String.ends_with?(path, ".bl") do
      raw
    else
      doc_source(raw, if(String.ends_with?(path, ".org"), do: :org, else: :md))
    end
  end
  @doc """
  The program of a livebook document: every code cell concatenated, in
  document order. `format` is `:md` for `.bl.md` (fenced beam-lisp cells)
  or `:org` for `.bl.org` (#+begin_src beam-lisp blocks).

  This is the loader's MINIMAL read-side extractor — it must stay
  dependency-free because it runs below the var registry, mid-load. The
  full-fidelity twin (ids, result spans, round-tripping) is `bl.doc` in
  priv/bl/doc.bl, and the test suite pins the two equal on every fixture.
  """
  def doc_source(raw, format) when format in [:md, :org] do
    raw
    |> String.split("\n")
    |> collect_doc_cells(format, [])
    |> Enum.reverse()
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp collect_doc_cells([], _format, acc), do: acc

  defp collect_doc_cells([line | rest], format, acc) do
    trimmed = String.trim(line)

    open? =
      if format == :md do
        String.starts_with?(trimmed, "```beam-lisp")
      else
        String.starts_with?(trimmed, "#+begin_src beam-lisp")
      end

    if open? do
      closer =
        if format == :md do
          fn l -> String.trim(l) == "```" end
        else
          fn l -> String.trim(l) == "#+end_src" end
        end

      {body, rest} = take_until(rest, closer)
      collect_doc_cells(rest, format, [body | acc])
    else
      collect_doc_cells(rest, format, acc)
    end
  end

  defp take_until(lines, pred), do: take_until(lines, pred, [])

  defp take_until([], _pred, acc), do: {Enum.reverse(acc), []}

  defp take_until([line | rest], pred, acc) do
    if pred.(line) do
      {Enum.reverse(acc), rest}
    else
      take_until(rest, pred, [line | acc])
    end
  end
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
  #
  # Between cwd and priv sit the EXTRA paths: `BEAM_LISP_PATH` (colon-
  # separated, like PATH) plus anything pushed by `Env.add_search_path/1`.
  # They exist because an application that lives outside cwd — `spell/src`
  # is the one in this repo — was previously reachable ONLY as the entry
  # file's own directory. That made `spell.machine` loadable by
  # `mix beam_lisp.run --path spell/study --path spell/src spell/study/main.bl`
  # and by nothing else: no test
  # suite could require it, because a suite pushes its OWN directory. A
  # library you cannot write a test against is a library you cannot move
  # code into, which is what blocked the priv/ → spell/ migration.
  #
  # Ordering is deliberate and load-bearing: pushed > cwd > extra > priv.
  # Extra sits BELOW cwd so a project file still shadows a configured
  # library, and ABOVE priv so an app can override a shipped library it
  # deliberately replaces.
  defp search_dirs do
    Env.load_paths() ++ ambient_dirs() ++ [Application.app_dir(:beam_lisp, "priv")]
  end

  # The ambient segment of `search_dirs/0`: the CALLER's captured roots
  # while a load runs inside Loader.Server (see ensure_loaded/1), else this
  # process's own env configuration.
  defp ambient_dirs do
    case Process.get(:bl_search_dirs) do
      nil -> [File.cwd!()] ++ extra_dirs()
      dirs -> dirs
    end
  end

  # Configured search paths, nearest first: explicitly added (a mix task
  # flag, a test setup) before environment-provided.
  defp extra_dirs do
    Env.search_paths() ++ env_paths()
  end

  defp env_paths do
    case System.get_env("BEAM_LISP_PATH") do
      nil -> []
      "" -> []
      s -> s |> String.split(":", trim: true) |> Enum.map(&Path.expand/1)
    end
  end
end
