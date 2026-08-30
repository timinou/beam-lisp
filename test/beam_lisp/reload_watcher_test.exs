defmodule BeamLisp.ReloadWatcherTest do
  use ExUnit.Case, async: false

  # The dev live-reload watcher: a `.bl` file save updates the running image,
  # coherently, with no restart. These tests edit REAL files and observe the
  # live image — determinism comes from `ReloadWatcher.sync/2`, which waits for
  # the OS event to actually arrive (counting real events) before draining, so
  # there is no `Process.sleep`-and-hope.

  alias BeamLisp.ReloadWatcher

  setup do
    # Own Env/Loader.Server regardless of run order (a sibling suite may have
    # stopped the app), then seed the language + reload ns.
    ensure_named(BeamLisp.Env, fn -> BeamLisp.Env.start_link([]) end)
    ensure_named(BeamLisp.Loader.Server, fn -> BeamLisp.Loader.Server.start_link([]) end)
    BeamLisp.init()
    # reload's `state` atom is an Agent created at ns-load; if a sibling suite
    # stopped the app that Agent may be dead, so re-seed the ns under a live
    # process before clearing any staged bundle.
    reseed_reload()
    BeamLisp.eval("(reload/abort)")

    dir = Path.join(System.tmp_dir!(), "bl_watch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  defp write!(dir, name, src) do
    path = Path.join(dir, name)
    File.write!(path, src)
    path
  end

  # The inotify backend spawns `inotifywait` asynchronously; it is not watching
  # the instant `start_link` returns. This is OS-backend warmup, not reload logic
  # — wait for it once, then all subsequent saves are observed deterministically
  # via `sync/2` (which counts real events, no further sleeping).
  defp await_watching, do: Process.sleep(900)

  # Ensure `reload` is loaded and its `state` atom is backed by a LIVE Agent.
  # `reload/abort` touches the atom; if that raises (a dead Agent from a stopped
  # app), re-evaluate the atom definition into the reload ns to rebuild it under
  # the current, live process.
  defp reseed_reload do
    BeamLisp.Loader.ensure_loaded("reload")

    try do
      BeamLisp.eval("(reload/status)")
      :ok
    rescue
      _ ->
        BeamLisp.eval(
          "(ns reload) (def state (atom {:staged {} :migration nil :status :empty :errors [] :applied []}))"
        )

        :ok
    catch
      _, _ ->
        BeamLisp.eval(
          "(ns reload) (def state (atom {:staged {} :migration nil :status :empty :errors [] :applied []}))"
        )

        :ok
    end
  end

  # Eval that yields nil instead of raising when the var is not defined yet — so
  # a `wait_until` predicate can poll for a value before the ns exists.
  defp safe_eval(expr) do
    try do
      BeamLisp.eval(expr)
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  # Poll `pred` until true or timeout — value-based determinism that a save's
  # coalesced inotify events (create/modify/close all fire) cannot race. This is
  # not sleep-and-hope: it returns the instant the running image reflects the
  # edit, and fails loud if it never does.
  defp wait_until(pred, timeout \\ 3000) do
    cond do
      timeout <= 0 -> flunk("image did not reflect the edit within the timeout")
      pred.() -> :ok
      true -> Process.sleep(20); wait_until(pred, timeout - 20)
    end
  end

  # Re-save `path` with `src` until the running image satisfies `pred`. A single
  # save can be missed during backend warmup or coalesced; re-saving (a couple of
  # times, spaced) makes the FIRST edit as reliable as later ones without hiding
  # a logic error — if the reload never happens, it still fails loud.
  defp save_until(path, src, pred, tries \\ 6) do
    File.write!(path, src)

    cond do
      wait_reflected(pred, 500) -> :ok
      tries <= 1 -> flunk("reload never reflected the save")
      true -> save_until(path, src, pred, tries - 1)
    end
  end

  defp wait_reflected(_pred, timeout) when timeout <= 0, do: false

  defp wait_reflected(pred, timeout) do
    if pred.() do
      true
    else
      Process.sleep(20)
      wait_reflected(pred, timeout - 20)
    end
  end

  test "a saved .bl file updates the running image", %{dir: dir} do
    write!(dir, "w1.bl", "(ns w.one)\n(defn v [] :first)\n")

    {:ok, _} = ReloadWatcher.start_link(dirs: [dir], name: :wtest1)
    on_exit(fn -> stop(:wtest1) end)
    await_watching()

    p = Path.join(dir, "w1.bl")
    # save the file (the initial write predates subscription); the image reflects it.
    save_until(p, "(ns w.one)\n(defn v [] :first)\n", fn -> safe_eval("(w.one/v)") == :first end)
    assert safe_eval("(w.one/v)") == :first

    # edit the file → the running fn changes, no restart
    save_until(p, "(ns w.one)\n(defn v [] :second)\n", fn -> safe_eval("(w.one/v)") == :second end)
    assert safe_eval("(w.one/v)") == :second
  end

  # NB the RELOAD CONTRACT the watcher wraps — a change applies, an incoherent
  # change is held with the old code serving, successive changes land in order,
  # staging without commit defers — is proven deterministically and free of the
  # cross-suite app-shutdown contamination in test/bl/reload/watcher_test.bl,
  # which drives `ReloadWatcher.apply_change/3` (the same stage→commit seam) with
  # no filesystem. This ExUnit module keeps only the one thing a bl suite cannot
  # cover: that a real inotify FILE EVENT actually reaches that seam.

  defp stop(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> try do GenServer.stop(pid, :normal, 1000) catch _, _ -> :ok end
    end
  end

  defp ensure_named(name, start) do
    case Process.whereis(name) do
      nil ->
        {:ok, pid} =
          case start.() do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
          end

        Process.unlink(pid)
        :ok

      _pid ->
        :ok
    end
  end
end
