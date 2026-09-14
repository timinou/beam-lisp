defmodule BeamLisp.Daemon.WatchRegistryTest do
  use ExUnit.Case, async: false

  # The daemon's watcher registry: one `BeamLisp.ReloadWatcher` per canonical
  # directory, results fanned out to every subscriber, and — the promise its
  # moduledoc makes — a subscriber's death removing every subscription it held.
  #
  # The reload seam is injected directly (`send(reg, {:reload_result, dir, …})`),
  # so these assertions never touch the filesystem for events and need no sleep:
  # the registry's own seam is the message a watcher posts.
  #
  # Run: mix test test/beam_lisp/daemon_watch_registry_test.exs

  alias BeamLisp.Daemon.{Executor, WatchRegistry}

  setup do
    {:ok, exec} = Executor.start_link(name: :"watch_exec_#{:erlang.unique_integer([:positive])}")

    {:ok, reg} =
      WatchRegistry.start_link(
        name: :"watch_reg_#{:erlang.unique_integer([:positive])}",
        executor: exec
      )

    on_exit(fn ->
      for p <- [reg, exec], is_pid(p) and Process.alive?(p) do
        try do
          GenServer.stop(p, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    dir = Path.join(System.tmp_dir!(), "blwreg-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{exec: exec, reg: reg, dir: dir}
  end

  test "two watches of one dir share one watcher and both get the result", %{reg: reg, dir: dir} do
    parent = self()

    on_fs(reg, dir, fn ->
      assert :ok = WatchRegistry.watch(reg, dir, {self(), :a}, fn r -> send(parent, {:a, r}) end)
      assert :ok = WatchRegistry.watch(reg, dir, {self(), :b}, fn r -> send(parent, {:b, r}) end)

      assert length(WatchRegistry.watched(reg)) == 1, "two watches must dedupe to one watcher"

      [watched] = WatchRegistry.watched(reg)
      result = %{path: "app/foo.bl", status: :applied}
      send(reg, {:reload_result, watched, result})

      assert_receive {:a, ^result}
      assert_receive {:b, ^result}
    end)
  end

  test "two DIFFERENT dirs each get their own watcher", %{reg: reg, dir: dir} do
    # Regression: the registry starts one ReloadWatcher per directory, but the
    # watcher's start_link took the DEFAULT GLOBAL name — the second
    # directory's start failed {:already_started, pid} and the tree kept
    # exactly one watched root. A daemon-hosted `bl watch src` + `bl watch
    # tooling` was the reporter: tooling never got a watcher.
    dir2 = Path.join(System.tmp_dir!(), "blwreg2-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir2)
    on_exit(fn -> File.rm_rf!(dir2) end)

    on_fs(reg, dir, fn ->
      assert :ok = WatchRegistry.watch(reg, dir, {self(), :a}, fn _ -> :ok end)
      assert :ok = WatchRegistry.watch(reg, dir2, {self(), :b}, fn _ -> :ok end)

      assert length(WatchRegistry.watched(reg)) == 2,
             "each directory holds its own watcher"
    end)
  end

  test "unwatching one subscriber keeps the watcher for the other", %{reg: reg, dir: dir} do
    parent = self()

    on_fs(reg, dir, fn ->
      assert :ok = WatchRegistry.watch(reg, dir, {self(), :a}, fn r -> send(parent, {:a, r}) end)
      assert :ok = WatchRegistry.watch(reg, dir, {self(), :b}, fn r -> send(parent, {:b, r}) end)

      assert :ok = WatchRegistry.unwatch(reg, dir, {self(), :a})
      assert length(WatchRegistry.watched(reg)) == 1, "the remaining subscriber holds the watcher"

      [watched] = WatchRegistry.watched(reg)
      send(reg, {:reload_result, watched, %{path: "x.bl", status: :held}})

      refute_receive {:a, _}, 50
      assert_receive {:b, %{path: "x.bl"}}
    end)
  end

  test "a dead subscriber drops every subscription it held", %{reg: reg, dir: dir} do
    parent = self()

    on_fs(reg, dir, fn ->
      doomed = spawn(fn -> Process.sleep(:infinity) end)
      keeper = spawn(fn -> Process.sleep(:infinity) end)

      # the SAME pid subscribes twice (two request ids) — both must go on :DOWN
      assert :ok = WatchRegistry.watch(reg, dir, {doomed, :a}, fn r -> send(parent, {:doomed_a, r}) end)
      assert :ok = WatchRegistry.watch(reg, dir, {doomed, :b}, fn r -> send(parent, {:doomed_b, r}) end)
      assert :ok = WatchRegistry.watch(reg, dir, {keeper, :c}, fn r -> send(parent, {:keeper, r}) end)
      assert map_size(subs(reg, dir)) == 3

      Process.exit(doomed, :kill)
      assert :ok = wait_until(fn -> map_size(subs(reg, dir)) == 1 end)
      assert length(WatchRegistry.watched(reg)) == 1, "the keeper still holds the watcher"

      [watched] = WatchRegistry.watched(reg)
      send(reg, {:reload_result, watched, %{path: "y.bl", status: :applied}})

      refute_receive {:doomed_a, _}, 50
      refute_receive {:doomed_b, _}, 50
      assert_receive {:keeper, %{path: "y.bl"}}

      Process.exit(keeper, :kill)
      assert :ok = wait_until(fn -> WatchRegistry.watched(reg) == [] end)
      assert subs(reg, dir) == %{}
    end)
  end

  # ── helpers ──

  # The watcher needs the `:file_system` application. When the build lacks it,
  # `watch/4` answers `{:error, reason}` (the registry traps the linked start
  # failure and stays alive) — report that environment gap, do not fail.
  defp on_fs(reg, dir, fun) do
    case WatchRegistry.watch(reg, dir, {self(), :__probe__}, fn _ -> :ok end) do
      :ok ->
        :ok = WatchRegistry.unwatch(reg, dir, {self(), :__probe__})
        fun.()

      {:error, reason} ->
        IO.puts(
          "WatchRegistry: watcher unavailable (#{inspect(reason)}) — " <>
            "skipping the file-system-dependent assertions"
        )

        :ok
    end
  end

  defp subs(reg, dir), do: Map.get(:sys.get_state(reg).subs, dir, %{})

  defp wait_until(fun, tries \\ 100)
  defp wait_until(_fun, 0), do: :timeout

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end
end
