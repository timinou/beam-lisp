# Cold-start counters for `bin/bl` (invoked only when BL_PROFILE=1).
#
# Sets up Erlang trace flags BEFORE the launcher runs, calls the launcher with
# timed seams, and dumps deterministic counters from its `halt` seam. The
# output is line-oriented on stderr:
#
#   bl-profile phase=<name> ms=<integer>
#   bl-count modules=<n> apps=<n> pt=<n> ets=<n> ports=<n>
#            file_calls=<n> file_reads=<n> file_stats=<n> file_opens=<n>
#            file_lists=<n> compile_forms=<n>
#
# It is deliberately separate from the launcher: production boot pays nothing.

defmodule ColdStartCounters do
  import Bitwise

  @file_funs [:read, :read_file, :open, :get_file_info, :read_link_info,
              :list_dir, :close, :write, :rename, :delete, :copy,
              :read_file_info, :del_file]

  def main do
    argv = System.argv()
    try do
      trace_on()
    catch
      :no_trace -> :ok
    end
    :persistent_term.put(:bl_profile_t0, now())
    BeamLisp.Launcher.boot(argv, seams())
  end

  # ── seams: time each effectful edge, keep the real implementations ─────────

  defp seams do
    %{
      install_hosts: timed1("install_hosts", &BeamLisp.Bootstrap.install_hosts!/1),
      manifest: timed0("manifest", &BeamLisp.Bootstrap.manifest/0),
      key_now: timed0("key_now", &BeamLisp.AOTCache.current_compiler_key/0),
      boot_namespaces: timed0("boot_namespaces", &BeamLisp.Tiers.boot_namespaces/0),
      provenance: timed1("provenance", &BeamLisp.AOT.beam_provenance/1),
      start_app: timed0("app_start", fn -> Application.ensure_all_started(:beam_lisp) end),
      ensure_loaded: timed1("ensure_loaded", &BeamLisp.Loader.ensure_loaded/1),
      fetch: timed2("fetch", &BeamLisp.Env.fetch!/2),
      invoke: timed2("invoke", &BeamLisp.Ns.Rt.invoke/2),
      stderr: fn msg -> IO.puts(:stderr, msg) end,
      halt: fn code -> finish(code) end
    }
  end

  # The launcher ends by halting; the counters must be printed BEFORE that.
  defp finish(code) do
    t0 = :persistent_term.get(:bl_profile_t0, now())
    IO.puts(:stderr, "bl-profile phase=total ms=#{now() - t0}")
    dump()
    System.halt(code)
  end

  defp timed0(name, f) do
    fn ->
      t = now()
      r = f.()
      emit(name, t)
      r
    end
  end

  defp timed1(name, f) do
    fn a ->
      t = now()
      r = f.(a)
      emit(name, t)
      r
    end
  end

  defp timed2(name, f) do
    fn a, b ->
      t = now()
      r = f.(a, b)
      emit(name, t)
      r
    end
  end

  defp emit(name, t) do
    c = flush(new_counts())
    IO.puts(:stderr, "bl-profile phase=#{name} ms=#{now() - t} " <>
                     "file=#{c.file} reads=#{c.reads} stats=#{c.stats} " <>
                     "lists=#{c.lists} compile=#{c.compile}")
  end

  defp now, do: System.monotonic_time(:millisecond)

  # ── the trace session ──────────────────────────────────────────────────────

  defp trace_on do
    if System.get_env("BL_PROFILE_TRACE") == "0" do
      :persistent_term.put(:bl_profile_trace, false)
      throw(:no_trace)
    end
    :erlang.trace_pattern({:prim_file, :_, :_}, true, [:local])
    :erlang.trace_pattern({:compile, :forms, :_}, true, [])
    :erlang.trace_pattern({:compile, :noenv_forms, :_}, true, [])
    :erlang.trace_pattern({:erlang, :open_port, 2}, true, [])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])
    :persistent_term.put(:bl_profile_trace, true)
  end

  # Drain every queued trace message, then wait until the runtime confirms all
  # tracees have delivered. Counting must not race the halt.
  defp dump do
    c = flush(new_counts())
    c =
      if :persistent_term.get(:bl_profile_trace, false) do
        ref = :erlang.trace_delivered(:all)
        flush(wait_delivered(ref, c))
      else
        c
      end
    IO.puts(:stderr,
      "bl-count modules=#{length(:code.all_loaded())} " <>
      "apps=#{length(:application.which_applications())} " <>
      "pt=#{Map.get(:persistent_term.info(), :count)} ets=#{length(:ets.all())} " <>
      "ports=#{c.ports} file_calls=#{c.file} file_reads=#{c.reads} " <>
      "file_stats=#{c.stats} file_opens=#{c.opens} file_lists=#{c.lists} " <>
      "compile_forms=#{c.compile}")
  end

  defp new_counts,
    do: %{file: 0, reads: 0, stats: 0, opens: 0, lists: 0, compile: 0, ports: 0}

  defp wait_delivered(ref, c) do
    receive do
      {:trace_delivered, :all, ^ref} -> c
      _other -> wait_delivered(ref, c)
    after
      2000 -> c
    end
  end

  defp flush(c) do
    receive do
      {:trace, _pid, :call, {:prim_file, fun, _args}} ->
        flush(bump(c, fun))
      {:trace, _pid, :call, {:compile, fun, _args}} when fun in [:forms, :noenv_forms] ->
        flush(%{c | compile: c.compile + 1})
      {:trace, _pid, :call, {:erlang, :open_port, _args}} ->
        flush(%{c | ports: c.ports + 1})
      _other ->
        flush(c)
    after
      0 -> c
    end
  end

  defp bump(c, fun) do
    c = %{c | file: c.file + 1}
    cond do
      fun == :read or fun == :read_file -> %{c | reads: c.reads + 1}
      fun in [:get_file_info, :read_link_info, :read_file_info] -> %{c | stats: c.stats + 1}
      fun == :open -> %{c | opens: c.opens + 1}
      fun == :list_dir -> %{c | lists: c.lists + 1}
      true -> c
    end
  end
end
