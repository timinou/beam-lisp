defmodule BeamLisp do
  @moduledoc """
  beam-lisp — jank's language, the BEAM's runtime.

  jank is a Clojure dialect native to C++; beam-lisp is the same idea
  aimed at the other native target that matters: the BEAM. The reader
  speaks jank-flavored Clojure, the compiler lowers forms to Elixir
  quoted expressions, and Elixir's compiler turns those into ordinary
  BEAM bytecode. Interop is not a bridge — `Module/function` calls
  compile straight to remote calls.

  ## Example

      iex> BeamLisp.eval("(defn square [x] (* x x)) (square 12)")
      144
      iex> BeamLisp.eval("(map inc [1 2 3])")
      [2, 3, 4]
      iex> BeamLisp.eval("(String/upcase \\"beam-native\\")")
      "BEAM-NATIVE"
  """

  alias BeamLisp.{Compiler, Env, RT}

  # The prelude ships inside the compiled module, not as a runtime
  # priv file: embedded runtimes (Mob device apps deploy flat .beam
  # dirs; escripts) have no :code.priv_dir/1 for :beam_lisp, so a
  # runtime File.read! would crash boot. @external_resource keeps
  # Mix recompiling when the .bl sources change.
  @prelude_path Path.join(__DIR__, "../priv/boot/core.bl")
  @multi_path Path.join(__DIR__, "../priv/std/multi.bl")
  @sugar_path Path.join(__DIR__, "../priv/boot/sugar.bl")
  @data_readers_path Path.join(__DIR__, "../priv/boot/data-readers.bl")
  @external_resource @prelude_path
  @external_resource @multi_path
  @external_resource @sugar_path
  @external_resource @data_readers_path
  @prelude File.read!(@prelude_path)
  @multi File.read!(@multi_path)
  @sugar File.read!(@sugar_path)
  @data_readers File.read!(@data_readers_path)

  @doc """
  Evaluate beam-lisp source, bootstrapping `core` on first use.

  Returns the value of the last form.
  """
  def eval(source) when is_binary(source) do
    init()
    Compiler.eval_string(source)
  end

  @doc "Evaluate a beam-lisp file. Returns the last value."
  def run_file(path) do
    init()

    BeamLisp.Loader.with_load_path(Path.dirname(path), fn ->
      # A document (.bl.md / .bl.org) works as an entry file too: its
      # program is its code cells, exactly as when it is `:require`d.
      source = BeamLisp.Loader.read_source(path)

      Compiler.eval_string(source, Compiler.new_env(), path)
    end)
  end

  @doc """
  The program arguments a `bl run FILE -- a b c` invocation exposes to the
  running program (the `a b c`). Process-local: a daemon request binds the
  CLIENT's post-`--` args via `with_argv/2`; outside a command context it
  falls back to the OS `System.argv/0`, so a plain `elixir`/escript run still
  sees its own arguments.
  """
  def argv do
    case Process.get(:bl_argv) do
      nil -> System.argv()
      list when is_list(list) -> list
    end
  end

  @doc "Run `fun` with `list` bound as the program argv (see `argv/0`)."
  def with_argv(list, fun) when is_list(list) do
    prev = Process.get(:bl_argv)
    Process.put(:bl_argv, list)

    try do
      fun.()
    after
      if is_nil(prev), do: Process.delete(:bl_argv), else: Process.put(:bl_argv, prev)
    end
  end

  @doc """
  The working directory a `bl` command resolves file arguments against.
  Process-local: a daemon request binds the CLIENT's cwd here (the daemon VM's
  own `File.cwd!/0` is the checkout, not the client's tree); outside a command
  context it falls back to the OS cwd, so a standalone run is unchanged.
  """
  def cwd do
    case Process.get(:bl_cwd) do
      nil -> File.cwd!()
      dir when is_binary(dir) -> dir
    end
  end

  @doc "Run `fun` with `dir` bound as the command cwd (see `cwd/0`)."
  def with_cwd(dir, fun) when is_binary(dir) do
    prev = Process.get(:bl_cwd)
    Process.put(:bl_cwd, dir)

    try do
      fun.()
    after
      if is_nil(prev), do: Process.delete(:bl_cwd), else: Process.put(:bl_cwd, prev)
    end
  end

  @doc "Seed the `core` namespace and load the prelude, once."
  def init do
    ensure_env()

    unless Env.seeded?() do
      RT.seed_core()

      # Prefer the AOT-compiled prelude, exactly as `Loader.ensure_loaded/1`
      # prefers a compiled namespace over its source. `mix compile.beam_lisp`
      # emits core.bl and multi.bl as real modules with `__bl_init__/0`, so
      # this loads the prelude from a `.beam` (~20ms) instead of recompiling
      # 65KB of core.bl on every boot (~6s — the cost every downstream script
      # was paying, the twin of the datom fix in e72b76d).
      #
      # `:no_module` falls back to evaluating the embedded source, so an
      # uncompiled checkout still boots — slowly, and correctly. The sources
      # are layered: core.bl is the language, multi.bl the dispatch library
      # built on it, so core must come first (list order).
      # sugar.bl is a THIRD layer: the threading/cond macros (cond->, some->,
      # condp, doto, fnil, …), kept out of core.bl to hold its size down but
      # loaded by default and referred everywhere (see BeamLisp.Env's `sugar`
      # fallback). Loads after core (it is pure macros over core) and after
      # multi, mirroring the AOT-first / source-fallback handling of both.
      for {ns, source} <- [{"core", @prelude}, {"multi", @multi}, {"sugar", @sugar}] do
        case BeamLisp.AOT.ensure_loaded(ns) do
          :loaded -> :ok
          :no_module -> Compiler.eval_string(source, Compiler.new_env("core"))
        end
      end

      # SELF-HOST CUTOVER — the prelude (core/multi/sugar) is now seeded, so the
      # .bl compiler's own runtime deps (`list`, `reduce`, the sugar macros)
      # resolve. Intern the .bl compiler + reader FROM THEIR BEAMS now, BEFORE
      # the `@data_readers` eval below: once interned, `compile/2` and
      # `read_string/2` delegate every later form to the self-hosted toolchain
      # (BeamLisp.Ns.Compiler / BeamLisp.Ns.Reader), so `@data_readers` — which
      # opens with `(ns data-readers)` and needs the compiler's special-forms —
      # runs through the LANGUAGE, not the Elixir genesis path. Interning replays
      # already-built def VALUES from the beam (no compilation). On a from-source
      # tree with no compiler beam these are no-ops: the ns stays un-interned and
      # `@data_readers` compiles via genesis, which is exactly what a bootstrap
      # build does. A load failure degrades to the configured backend; boot never
      # breaks. (`:compiler_backend`/`:reader_backend :genesis` opt out.)
      try do
        BeamLisp.Compiler.enable_bl_backend()
      rescue
        _ -> :genesis
      end

      try do
        BeamLisp.Reader.enable_bl_reader()
      rescue
        _ -> :genesis
      end

      # Seed the built-in tagged-literal registry (`#d`, `#time`) from source,
      # AFTER core (it calls `data-reader!`) and BEFORE any user file is read.
      # This is what lets the tag→reader-fn mappings live in beam-lisp
      # (`priv/boot/data-readers.bl`) instead of a hardcoded Elixir default — the
      # reader reads a whole file before evaluating it, so a same-file
      # registration would lose the race, but a boot-time one never does.
      # Evaluated directly (not AOT-cached): it is three side-effecting forms,
      # not a var-bearing namespace, so there is nothing to intern or reuse.
      Compiler.eval_string(@data_readers, Compiler.new_env("core"))

      Env.mark_seeded()

      Env.in_ns("user")
    end

    :ok
  end

  # Embedded runtimes (Mob device apps, escripts, one-shot `-eval`
  # boots) never start the :beam_lisp OTP application, so the Env
  # Agent that owns the var table may not exist. Start it on demand;
  # when the OTP app did start, the whereis check is already
  # satisfied and this is a no-op.
  defp ensure_env do
    case Process.whereis(Env) do
      nil ->
        case Env.start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  @doc "A read-eval-print loop. Exit with Ctrl+C or by evaluating `(System/halt)`."
  def repl do
    init()
    IO.puts("beam-lisp #{vsn()} — jank's language, the BEAM's runtime. (Ctrl+C to exit)")
    repl_loop()
  end

  defp repl_loop do
    case IO.gets("#{Env.current_ns()}=> ") do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        try do
          line |> Compiler.eval_string() |> RT.print_str() |> IO.puts()
        rescue
          e -> IO.puts("error: #{Exception.message(e)}")
        end

        repl_loop()
    end
  end

  defp vsn do
    {:ok, vsn} = :application.get_key(:beam_lisp, :vsn)
    List.to_string(vsn)
  end
end
