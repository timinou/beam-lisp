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

  @doc """
  Evaluate beam-lisp source, bootstrapping `core` on first use.

  Returns the value of the last form.
  """
  def eval(source) when is_binary(source) do
    init()
    Compiler.eval_string(source)
  end

  @doc "Seed the `core` namespace and load the prelude, once."
  def init do
    unless Env.seeded?() do
      RT.seed_core()
      Compiler.eval_string(File.read!(prelude_path()), Compiler.new_env("core"))
      Env.mark_seeded()
    end

    :ok
  end

  defp prelude_path, do: Application.app_dir(:beam_lisp, "priv/core.bl")

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
