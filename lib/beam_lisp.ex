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
  @prelude_path Path.join(__DIR__, "../priv/core.bl")
  @multi_path Path.join(__DIR__, "../priv/multi.bl")
  @external_resource @prelude_path
  @external_resource @multi_path
  @prelude File.read!(@prelude_path)
  @multi File.read!(@multi_path)

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
      path |> File.read!() |> Compiler.eval_string(Compiler.new_env(), path)
    end)
  end

  @doc "Seed the `core` namespace and load the prelude, once."
  def init do
    ensure_env()

    unless Env.seeded?() do
      RT.seed_core()
      # The prelude is layered: core.bl is the language, multi.bl the
      # dispatch library that builds on it (derive/isa? and friends
      # are ordinary beam-lisp over BeamLisp.Multi).
      for source <- [@prelude, @multi] do
        Compiler.eval_string(source, Compiler.new_env("core"))
      end

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
