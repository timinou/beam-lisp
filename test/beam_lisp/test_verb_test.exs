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

  test "the shared escape runs the FILES, not every suite this VM has run", %{dir: dir} do
    write(dir, "test/plain_test.bl", "(ns plain-test)\n(deftest fine (is (= 1 1)))\n")

    # Two runs in ONE image. `--shared` forks the caller's image, so the second
    # run's registry holds the files it named and nothing else; before that fork
    # `run-tests :all` meant "everything this image ever ran", and a second run
    # answered with the first run's tests — or, inside a warm daemon, with tests
    # from the request before it.
    {code, out} = run(dir, ["test", "--shared"])
    assert code == 0, "the shared run must be green; it said:\n#{out}"
    {code2, out2} = run(dir, ["test", "--shared"])
    assert code2 == 0, "the second shared run must be green; it said:\n#{out2}"

    ran = fn text -> Regex.run(~r/Ran (\d+) tests?/, text) |> List.last() end
    assert ran.(out) == ran.(out2),
           "the same files must run the same tests; first #{ran.(out)}, then #{ran.(out2)}"
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

  # ── how a test file is READ ──
  #
  # A `.bl.md` / `.bl.org` test file is a DOCUMENT whose program is its code
  # cells, and a `.bl` script may open with a `#!/usr/bin/env bl` shebang. Both
  # are the loader's business: the runner reads through `Loader.read_source/1` —
  # the loader's own read, the one `bl run`, `bl build` and `require` use — so
  # the prose between the cells never reaches the reader and the shebang line is
  # stripped. A raw read reached the reader with both: every literate file
  # answered `INCOHERENT — test file declares no (ns …) form` however clean its
  # cells were, `--shared`/`--async` died on the document's first `#` heading,
  # and a shebanged script died on `unresolved qualified name #!/usr/bin/env`.

  @literate_md """
  # A literate test

  This prose is not code. `(ns prose-decoy)` is a sentence here, and so is
  `(deftest prose-decoy (is false))`.

  ```beam-lisp
  (ns doc-test)
  ```

  A cell that passes:

  ```beam-lisp
  (deftest lit-passes (is (= 2 (+ 1 1))))
  ```

  A fence in another language is not this file's program:

  ```clojure
  (deftest wrong-language (is false))
  ```
  """

  test "a literate .bl.md test runs its code cells, not its prose", %{dir: dir} do
    rel = "test/doc_test.bl.md"
    write(dir, rel, @literate_md)

    # The read the runner uses, asserted at the seam: the cells are the program,
    # the prose (and a fence in another language) is not.
    src = BeamLisp.Loader.read_source(Path.join(dir, rel))
    assert src =~ "(ns doc-test)"
    refute src =~ "prose-decoy"
    refute src =~ "wrong-language"

    {code, out} = run(dir, ["test", "test/doc_test.bl.md"])
    assert code == 0, "a literate file must run; it said:\n#{out}"
    assert out =~ "✓ doc-test", "the ns comes from the cells"
    assert out =~ "1 passed", "one test: the one the cells declare"
    refute out =~ "prose-decoy", "prose is not code"
    refute out =~ "wrong-language", "nor is a fence in another language"
  end

  @literate_org """
  #+TITLE: A literate org test

  The prose here is not code; (ns prose-decoy) is a sentence.

  #+begin_src beam-lisp
  (ns org-test)
  #+end_src

  #+begin_src beam-lisp
  (deftest org-fails (is (= 1 2)))
  #+end_src
  """

  test "a literate .bl.org test is red on its code, with the why", %{dir: dir} do
    write(dir, "test/org_test.bl.org", @literate_org)

    {code, out} = run(dir, ["test", "test/org_test.bl.org"])
    assert code == 1, "the failing cell makes the run red; it said:\n#{out}"
    assert out =~ "org-test", "the ns comes from the cells"
    assert out =~ "org-fails", "the failing test is named"
    assert out =~ "expected:", "and the why is reported, not a prose crash"
    assert out =~ "actual:"
    refute out =~ "prose-decoy"
  end

  test "a shebanged script is a test file, as it is under bl run", %{dir: dir} do
    write(
      dir,
      "test/script_test.bl",
      "#!/usr/bin/env bl\n(ns script-test)\n(deftest a (is true))\n"
    )

    {code, out} = run(dir, ["test", "test/script_test.bl"])
    assert code == 0, "an executable test script must run; it said:\n#{out}"
    assert out =~ "✓ script-test"
    assert out =~ "1 passed"
  end

  test "a literate file runs the same under --shared and --async", %{dir: dir} do
    write(dir, "test/doc_test.bl.md", @literate_md)

    for mode <- ["--shared", "--async"] do
      {code, out} = run(dir, ["test", "test/doc_test.bl.md", mode])
      assert code == 0, "#{mode} must run the literate file; it said:\n#{out}"
      assert out =~ "Ran 1 tests", "#{mode} runs the one test the cells declare"
      refute out =~ "prose-decoy", "#{mode} reads the cells, not the prose"
    end
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

  # The daemon is pure beam-lisp now (vm.session composes vm.net + vm.io +
  # vm.manager + bl.daemon). Boot it through the runtime and speak the SAME
  # AF_UNIX wire a real client speaks — raw ETF frames, the vm.paths endpoints.
  defp daemon_request(ctx, argv, dir) do
    root = File.cwd!()
    BeamLisp.Loader.ensure_loaded("vm.session")
    BeamLisp.Loader.ensure_loaded("vm.paths")

    started = BeamLisp.RT.invoke(BeamLisp.Env.fetch!("vm.session", "start"), [root])
    listener = Map.fetch!(started, :ok)

    ep = Map.fetch!(BeamLisp.RT.invoke(BeamLisp.Env.fetch!("vm.paths", "endpoints"), [root]), :ok)
    sock_path = Map.fetch!(ep, :sock)
    token_path = Map.fetch!(ep, :token)

    wait_for(fn -> File.exists?(token_path) end)
    token = File.read!(token_path)
    tree = BeamLisp.RT.invoke(BeamLisp.Env.fetch!("vm.paths", "fingerprint"), [root])

    {:ok, sock} =
      :gen_tcp.connect({:local, String.to_charlist(sock_path)}, 0, [
        {:inet_backend, :inet},
        :local,
        :binary,
        {:packet, 4},
        {:active, false}
      ])

    :gen_tcp.send(sock, :erlang.term_to_binary({:bl, 1, :hello, %{tree: tree, token: token}}))
    {:ok, _} = :gen_tcp.recv(sock, 0, 10_000)
    id = :crypto.strong_rand_bytes(16)
    :gen_tcp.send(sock, :erlang.term_to_binary({:bl, 1, :request, id, %{argv: argv, cwd: dir, env: %{}}}))
    result = collect(sock, id, "")
    :gen_tcp.close(sock)

    _ = BeamLisp.RT.invoke(BeamLisp.Env.fetch!("vm.session", "stop"), [listener])
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
