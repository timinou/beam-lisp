defmodule BeamLisp.BuildSessionTest do
  @moduledoc """
  W8 — a build is a SESSION: a claim names its owner, and the work is visible in
  one journal.

  What this replaces: Mix serializes builds on a lock file in `_build`, and that
  lock is 0 bytes naming nobody (measured). cargo holds its own target lock the
  same way. So the properties asserted here are the ones a lock cannot give:

    * a live claim REFUSES a second builder, naming the pid that holds it —
      rather than waiting on it, which is what a lock does and why a wedged lock
      is indistinguishable from a slow build;
    * a claim whose owner is GONE is swept, so a killed build does not wedge the
      tree forever;
    * the native stage is claimed per crate AND keyed by content, so a second
      build finds the artifact instead of running cargo again;
    * a build writes :"build/start" and :"build/done" into `reload`'s journal, so the
      build appears in the same stream as every other change to the image.
  """
  use ExUnit.Case, async: false

  setup do
    BeamLisp.init()
    BeamLisp.Loader.ensure_loaded("claim")
    cache = Path.join(System.tmp_dir!(), "beam_lisp_session_#{System.pid()}")
    File.rm_rf!(cache)
    File.mkdir_p!(cache)
    System.put_env("XDG_CACHE_HOME", cache)
    on_exit(fn -> System.delete_env("XDG_CACHE_HOME") end)
    %{cache: cache}
  end

  defp call(ns, f, args) do
    BeamLisp.Loader.ensure_loaded(ns)
    BeamLisp.RT.invoke(BeamLisp.Env.fetch!(ns, f), args)
  end

  test "a live claim refuses a second builder and names the holder", %{cache: cache} do
    dir = Path.join(cache, "claimed")
    File.mkdir_p!(dir)

    assert call("claim", "acquire!", [dir, "first"])[:ok?]

    # A FOREIGN live pid: a real process this VM does not own (the test VM's own
    # pid would read as OURS — `held-by` treats same-pid as not-a-conflict, and
    # the first version of this test used it and learned that the hard way).
    port = Port.open({:spawn_executable, System.find_executable("sleep")}, [{:args, ["30"]}])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    pid = to_string(os_pid)
    File.write!(Path.join(dir, ".claim"), "[:claim #{pid} 1 someone-else]")

    held = call("claim", "held-by", [dir])
    assert held[:pid] == pid
    assert held[:bin] == "someone-else"
    refute call("claim", "acquire!", [dir, "second"])[:ok?]
    assert call("claim", "acquire!", [dir, "second"])[:held][:pid] == pid,
           "a refusal must NAME the holder — that is the difference from a lock"

    # A claim whose pid still has a `/proc` entry is HONOURED, even if the process
    # is a zombie: liveness here is deliberately conservative (see `claim`), and
    # the cost of being wrong in the other direction is stomping another build.
    # The swept case — a pid with no `/proc` entry at all — is the next test.
    Port.close(port)
    assert call("claim", "held-by", [dir])[:pid] == pid
  end

  test "a claim whose owner is gone is swept, not honoured", %{cache: cache} do
    dir = Path.join(cache, "dead")
    File.mkdir_p!(dir)
    # A pid that cannot exist: /proc answers for real processes only.
    File.write!(Path.join(dir, ".claim"), "[:claim 999999999 1 a-build-that-died]")

    assert call("claim", "held-by", [dir]) == nil
    r = call("claim", "acquire!", [dir, "sweeper"])
    assert r[:ok?]
    assert r[:swept], "the stale claim should have been reported as swept"
    assert call("claim", "read-claim", [dir])[:bin] == "sweeper"
  end

  test "a claim by THIS process is ours, not a conflict", %{cache: cache} do
    dir = Path.join(cache, "mine")
    call("claim", "acquire!", [dir, "me"])
    assert call("claim", "held-by", [dir]) == nil
    assert call("claim", "acquire!", [dir, "me again"])[:ok?]
    assert call("claim", "release!", [dir]) == :ok
    assert call("claim", "read-claim", [dir]) == nil
  end

  # The native stage is bl code and is exercised from bl — see
  # `test/bl/native_test.bl`, where the call is the one the build itself makes.
  # Reaching it from here would mean going through the Elixir/ bl boundary for no
  # extra coverage.

  # The CLI is the thing that journals a build, and `bl.cli/run-argv` is the
  # re-entrant seam that makes it testable from here: it parses argv, takes the
  # claim, writes the events and releases the claim, all in THIS VM — so the
  # journal it writes is the journal this test reads.
  #
  # What this replaced: a `System.cmd("mix", ["bl", "build", …])`. A subprocess
  # is a separate VM with its own journal, so the test could not assert on
  # anything the build wrote — it spawned the build, threw the result away, then
  # fired the two events by hand and asserted they were there. It timed out at
  # the 60 s default on a cold tree (the subprocess recompiles the prelude) and
  # its own comment admitted the assertion proved nothing about the build. The
  # same run then raced the next test's `File.rm_rf!` on a fixed /tmp path.
  @tag :slow
  test "the CLI build writes build/start and build/done into the journal", %{cache: cache} do
    out = Path.join(cache, "out")
    src = Path.join(cache, "src/tiny.bl")
    File.mkdir_p!(Path.dirname(src))
    File.write!(src, "(ns tiny) (defn answer [] 42)\n")

    BeamLisp.Loader.ensure_loaded("bl.cli")
    run = BeamLisp.Env.fetch!("bl.cli", "run-argv")

    before = call("reload", "journal", []) |> BeamLisp.Vector.to_list() |> length()
    # Bind THIS command's cwd to the scratch tree, the way the daemon binds a
    # client's. Without it the build discovers the REPO's env.bl by walking up
    # from the VM's cwd, and its `:ex` stage compiles all of lib/**/*.ex inside
    # this test — which is what made it exceed the 60 s budget when the
    # subprocess was replaced by an in-process call.
    code =
      BeamLisp.with_cwd(cache, fn ->
        BeamLisp.RT.invoke(run, [["build", src, "--out", out]])
      end)
    assert code == 0

    j = call("reload", "journal", []) |> BeamLisp.Vector.to_list()
    assert length(j) == before + 2, "a build journals exactly its start and its finish"

    [start, done] = Enum.take(j, -2)
    assert start[:event] == :"build/start" and start[:out] == out
    assert done[:event] == :"build/done" and done[:built] == 1 and done[:errors] == 0

    # the claim is the build's exclusion, and a build that returns must not
    # leave the directory wedged for the next one
    refute File.exists?(Path.join(out, ".claim")), "a finished build releases its claim"
  end
end
