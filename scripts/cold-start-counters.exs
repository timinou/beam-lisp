# Cold-start counters for `bin/bl` (invoked only when BL_PROFILE=1).
#
# Sets up Erlang trace flags BEFORE the launcher runs, calls the launcher with
# timed seams, and dumps deterministic counters from its `halt` seam. The
# output is line-oriented on stderr:
#
#   bl-profile phase=<name> ms=<integer>
#   bl-seam mfa=<Module.fun/arity> calls=<n> us=<n> ms=<f> share=<f>%
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

  # SDK-class preparation seams. These are LOCAL functions in the pinned host,
  # so they are measured with tprof call_time (`local` tracing), not with a
  # per-call trace message. Cached data still has to revalidate on every use;
  # a seam that vanishes from this table would hide that cost.
  @seam_mfas [
    {:"Elixir.BeamLisp.Env", :prepare_sdk_class!, 1},
    {:"Elixir.BeamLisp.AOT", :sdk_class_evidence!, 1},
    {:"Elixir.BeamLisp.Env", :retain_sdk_runtime!, 0},
    {:"Elixir.BeamLisp.AOT", :bootstrap_sdk_native_hosts!, 0},
    {:"Elixir.BeamLisp.Env", :sdk_runtime_inventory_cached!, 0},
    {:"Elixir.BeamLisp.AOT", :sdk_runtime_inventory!, 1},
    {:"Elixir.BeamLisp.AOT", :inventory_term, 1},
    {:"Elixir.BeamLisp.Env", :sdk_runtime_retained_modules?, 1},
    # Phase detail behind the two dominant seams (SDK prep, not separately cut).
    {:"Elixir.BeamLisp.AOT", :complete_source_sdk_closure!, 1},
    {:"Elixir.BeamLisp.AOT", :sdk_source_target_inventory!, 1},
    {:"Elixir.BeamLisp.AOT", :source_seed_inventory!, 0},
    {:"Elixir.BeamLisp.AOT", :source_sdk_receipts, 0},
    {:"Elixir.BeamLisp.AOT", :sdk_source_dependency!, 1},
    {:"Elixir.BeamLisp.AOT", :stage_sdk_dependency!, 3},
    {:"Elixir.BeamLisp.AOT", :sdk_native_source_declaration, 2},
    {:"Elixir.BeamLisp.Tiers", :dirs, 1}
  ]

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
      start_app: fn -> timed_app_start() end,
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

  # Time application start twice over: wall, and tprof call_time for the SDK
  # seams. `BL_PROFILE_SEAMS=0` skips tprof so the wall number is clean; the
  # seam rows are only meaningful in the tprof run. The tprof server setup is
  # inside the wall number; compare against that same run for shares.
  defp timed_app_start do
    t = now()
    {result, profile} =
      if System.get_env("BL_PROFILE_SEAMS") == "0" do
        {Application.ensure_all_started(:beam_lisp), :none}
      else
        :tprof.profile(
          fn -> Application.ensure_all_started(:beam_lisp) end,
          %{type: :call_time, pattern: @seam_mfas, report: :return,
            rootset: rootset()}
        )
      end
    elapsed = now() - t
    emit_seams(profile, elapsed)
    emit("app_start", t)
    result
  end

  # The Application callback does not run in the caller process: it runs under
  # an application master spawned by application_controller. `set_on_spawn`
  # covers its descendants, but the controller is not one, so name it.
  defp rootset do
    [Process.whereis(:application_controller)]
    |> Enum.reject(&is_nil/1)
  end

  defp emit_seams(:none, _elapsed), do: :ok

  defp emit_seams({:call_time, entries}, elapsed_us) do
    Enum.each(entries, fn {mod, fun, arity, per_pid} ->
      calls = Enum.reduce(per_pid, 0, fn {_pid, c, _us}, acc -> acc + c end)
      us = Enum.reduce(per_pid, 0, fn {_pid, _c, t}, acc -> acc + t end)
      share = if elapsed_us > 0, do: Float.round(us * 100 / (elapsed_us * 1000), 2), else: 0.0
      IO.puts(:stderr,
        "bl-seam mfa=#{inspect(mod)}.#{fun}/#{arity} calls=#{calls} " <>
        "us=#{us} ms=#{Float.round(us / 1000, 3)} share=#{share}%")
    end)
  end

  defp emit_seams(_other, _elapsed), do: :ok

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
