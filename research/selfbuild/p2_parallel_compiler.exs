# W0-P2 — can the drop compile the Elixir substrate in-process, with no Mix?
#
# Runs INSIDE the drop's VM:
#   <release>/bin/bl eval 'Code.eval_file("<abs>/p2_parallel_compiler.exs")'
# Env: BL_TREE = tree to compile (default cwd); BL_W0 = scratch (default /tmp/bl-w0)
#
# The hypothesis: Elixir's own compiler ships in the payload (it does), so
# `lib/**/*.ex` minus the Mix-task shells and the dev-only server compiles with
# no Mix project, no _build, no MIX_ENV. If true, `bl release` can build the
# substrate inside the shipped binary.

root = System.get_env("BL_TREE") || File.cwd!()
exclude = ["lib/dev", "lib/mix"]
out = Path.join(System.get_env("BL_W0") || "/tmp/bl-w0", "p2-ebin")

files =
  Path.wildcard(Path.join(root, "lib/**/*.ex"))
  |> Enum.reject(fn f ->
    rel = Path.relative_to(f, root)
    Enum.any?(exclude, &String.starts_with?(rel, &1))
  end)

File.rm_rf!(out)
File.mkdir_p!(out)

IO.puts("P2  tree=#{root}")
IO.puts("P2  files=#{length(files)} out=#{out}")
IO.puts("P2  mix_loaded=#{Code.ensure_loaded?(Mix)} parallel_compiler=#{Code.ensure_loaded?(Kernel.ParallelCompiler)}")

Code.compiler_options(ignore_module_conflict: true)

started = System.monotonic_time(:millisecond)

result =
  try do
    Kernel.ParallelCompiler.compile_to_path(files, out)
  rescue
    e -> {:raised, Exception.format(:error, e, __STACKTRACE__)}
  catch
    kind, v -> {:caught, {kind, v}}
  end

ms = System.monotonic_time(:millisecond) - started
beams = out |> File.ls!() |> Enum.count(&String.ends_with?(&1, ".beam"))

case result do
  {:ok, mods, warns} ->
    IO.puts("P2  RESULT ok modules=#{length(mods)} warnings=#{length(warns)} beams=#{beams} ms=#{ms}")
    IO.puts("P2  sample: #{mods |> Enum.take(3) |> inspect()}")

  {:error, errs, warns} ->
    IO.puts("P2  RESULT error errors=#{length(errs)} warnings=#{length(warns)} beams=#{beams} ms=#{ms}")

    for {file, err} <- Enum.take(errs, 6) do
      IO.puts("P2    #{inspect(file)}: #{inspect(err)}")
    end

  other ->
    IO.puts("P2  RESULT other=#{inspect(other)} beams=#{beams} ms=#{ms}")
end
