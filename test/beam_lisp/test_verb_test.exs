defmodule BeamLisp.TestVerbTest do
  @moduledoc """
  `bl test` — the shapes, run from a place with no ward of its own.

  The isolated runner forks one env per file and is NOT reentrant on itself, so
  a bl-language test file cannot start a suite inside a suite. These cases drive
  the CLI directly from ExUnit, where the outer runner is the ordinary test VM:
  a green suite is green, a failing one fails with the why, a file that explodes
  at load is contained while its sibling still runs, and files cannot see each
  other's world.
  """

  use ExUnit.Case, async: false

  setup do
    BeamLisp.AOT.boot()
    BeamLisp.Loader.ensure_loaded("bl.cli")

    dir =
      Path.join(System.tmp_dir!(), "bl_testverb_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, "test"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "a passing suite is green", %{dir: dir} do
    write(dir, "test/ok_test.bl", "(ns ok-test)\n(deftest fine (is (= 4 (* 2 2))))\n")
    {code, out} = run(dir, ["test"])
    assert code == 0
    assert out =~ "ok-test"
    assert out =~ "1 passed"
  end

  test "a failing test fails the run, with the why", %{dir: dir} do
    write(dir, "test/bad_test.bl", "(ns bad-test)\n(deftest wrong (is (= 1 2)))\n")
    {code, out} = run(dir, ["test"])
    assert code == 1
    assert out =~ "wrong"
    assert out =~ "expected"
  end

  test "a file that crashes at load is contained", %{dir: dir} do
    write(dir, "test/explodes_test.bl", """
    (ns explodes-test)
    (throw "kaboom at load")
    (deftest never (is true))
    """)

    write(dir, "test/after_test.bl", "(ns after-test)\n(deftest runs (is true))\n")

    {code, out} = run(dir, ["test"])
    assert code == 1, "the run is not green"
    assert out =~ "INCOHERENT"
    assert out =~ "after-test", "and the sibling still ran"
  end

  test "files cannot see each other's world", %{dir: dir} do
    write(dir, "test/definer_test.bl", """
    (ns definer-test)
    (def secret 42)
    (deftest ok (is (= 42 secret)))
    """)

    write(dir, "test/peeker_test.bl", """
    (ns peeker-test)
    (deftest cannot-see
      (is (= :isolated (try (BeamLisp.Env/fetch! "definer-test" "secret")
                            (catch _ :isolated)))))
    """)

    {code, out} = run(dir, ["test"])
    assert code == 0
    assert out =~ "2 file(s) passed"
  end

  test "the shared escape still runs the suite", %{dir: dir} do
    write(dir, "test/plain_test.bl", "(ns plain-test)\n(deftest fine (is (= 1 1)))\n")
    {code, _out} = run(dir, ["test", "--shared"])
    assert code == 0
  end

  test "the aggregate is available as JSON", %{dir: dir} do
    write(dir, "test/one_test.bl", "(ns one-test)\n(deftest a (is true))\n")
    {code, out} = run(dir, ["test", "--json"])
    assert code == 0, "the suite must be green; it said:\n#{out}"
    assert %{"pass" => 1, "fail" => 0, "error" => 0, "files" => 1} = Jason.decode!(last_json_line(out))
  end

  test "a warm suite runs through the daemon", %{dir: dir} = ctx do
    write(dir, "test/warm_test.bl", "(ns warm-test)\n(deftest warm (is true))\n")

    # The daemon serves `bl test` like any other command: ward's forks happen
    # INSIDE the one request, so the warm image is shared and each file still
    # gets its own env — no new request type is needed for isolation.
    {code, out} = daemon_request(ctx, ["test"], dir)
    assert code == 0
    assert out =~ "warm-test"
  end

  test "a test library that vanished from core's MODULE is re-loaded", %{dir: dir} do
    write(dir, "test/rel_test.bl", "(ns rel-test)\n(deftest a (is (= 1 1)))\n")

    # The observed failure state: a later reload puts core back from its BEAM,
    # which carries core.bl alone — so the assertion runtime the `is` macro
    # expands into is gone from the module, while `deftest` still resolves in
    # core's ENV. ward's guard checked the env alone, said "available", skipped
    # the load, and every file in the run then died on `is-report/4 is undefined`.
    :code.purge(BeamLisp.Ns.Core)
    :code.delete(BeamLisp.Ns.Core)
    {:module, _} = :code.load_file(BeamLisp.Ns.Core)

    refute :erlang.function_exported(BeamLisp.Ns.Core, :"is-report", 4),
           "precondition: the beam carries core.bl alone"

    {code, out} = run(dir, ["test"])
    assert code == 0, "a run in this state must still work; it said:\n#{out}"
  end

  # ── helpers ──

  defp write(dir, rel, text) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  # The CLI, cold: cwd bound the way a daemon request binds its client's.
  defp run(dir, argv) do
    {:ok, io} = StringIO.open("")

    prev = Process.group_leader()
    Process.group_leader(self(), io)
    Process.put(:bl_cwd, dir)

    code =
      try do
        BeamLisp.RT.invoke(BeamLisp.Env.fetch!("bl.cli", "run-argv"), [argv])
      after
        Process.group_leader(self(), prev)
        Process.delete(:bl_cwd)
      end

    {_, out} = StringIO.contents(io)
    {code, out}
  end

  defp daemon_request(ctx, argv, dir) do
    alias BeamLisp.Daemon.{Paths, Protocol, Server}

    root = File.cwd!()

    case Process.whereis(Server) do
      nil -> :ok
      old -> try do: GenServer.stop(old, :normal, 2_000), catch: (:exit, _ -> :ok)
    end

    {:ok, pid} = Server.start_link(root: root, boot: true, idle_seconds: 0)
    {:ok, ep} = Paths.endpoints(root)

    wait_for(fn -> File.exists?(ep.token) end)
    token = File.read!(ep.token)
    tree = Paths.tree_fingerprint(root)

    {:ok, sock} =
      :gen_tcp.connect({:local, String.to_charlist(ep.sock)}, 0, [
        {:inet_backend, :inet},
        :local,
        :binary,
        {:packet, 4},
        {:active, false}
      ])

    :gen_tcp.send(sock, Protocol.encode({:bl, 1, :hello, %{tree: tree, token: token}}))
    {:ok, _} = :gen_tcp.recv(sock, 0, 10_000)
    id = :crypto.strong_rand_bytes(16)
    :gen_tcp.send(sock, Protocol.encode({:bl, 1, :request, id, %{argv: argv, cwd: dir, env_paths: []}}))
    result = collect(sock, id, "")
    :gen_tcp.close(sock)

    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 2_000)
    _ = ctx
    result
  end

  defp wait_for(fun, tries \\ 250)

  defp wait_for(_fun, 0), do: :timeout

  defp wait_for(fun, tries) do
    if fun.(), do: :ok, else: (Process.sleep(20); wait_for(fun, tries - 1))
  end

  defp collect(sock, id, acc) do
    case :gen_tcp.recv(sock, 0, 120_000) do
      {:ok, bin} ->
        case :erlang.binary_to_term(bin) do
          {:bl, 1, :stdout, ^id, _s, b} -> collect(sock, id, acc <> b)
          {:bl, 1, :stderr, ^id, _s, b} -> collect(sock, id, acc <> b)
          {:bl, 1, :exit, ^id, code} -> {code, acc}
          _ -> collect(sock, id, acc)
        end

      _ ->
        {acc, :closed}
    end
  end

  defp last_json_line(out) do
    out |> String.split("\n") |> Enum.reject(&(String.trim(&1) == "")) |> List.last()
  end
end
