defmodule BeamLisp.LoaderPathTest do
  @moduledoc """
  The loader's configurable search paths.

  These exist for one concrete reason: a library that lives outside cwd was
  reachable ONLY as an entry file's own directory, so `spell/src/spell/*.bl`
  could be run but never *tested* — a suite pushes its own directory, not the
  library's. Code you cannot write a test against is code you cannot safely
  move, which is what blocked the priv/ → spell/ migration.

  The tests below assert PRECEDENCE, not merely resolution. "The loader found
  a file" is the weak claim; "the loader preferred the right file when two
  declare the same ns" is the one that keeps a configured root from silently
  shadowing a project's own source.
  """
  use ExUnit.Case, async: false

  alias BeamLisp.{Env, Loader}

  setup do
    BeamLisp.init()
    Env.clear_search_paths()
    System.delete_env("BEAM_LISP_PATH")
    on_exit(fn ->
      Env.clear_search_paths()
      System.delete_env("BEAM_LISP_PATH")
    end)

    :ok
  end

  defp write_ns!(dir, ns, body) do
    File.mkdir_p!(dir)
    path = Path.join(dir, String.replace(ns, ".", "/") <> ".bl")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "(ns #{ns})\n#{body}\n")
    path
  end

  # A fresh ns name per test: namespaces load ONCE per session, so reusing a
  # name across tests would have the second test assert against the first
  # test's already-loaded vars — green regardless of the loader's behaviour.
  defp uniq_ns(prefix), do: "#{prefix}#{System.unique_integer([:positive])}"

  test "add_search_path makes an out-of-cwd library requirable" do
    dir = Path.join(System.tmp_dir!(), "blpath_#{System.unique_integer([:positive])}")
    ns = uniq_ns("lptest_lib")
    write_ns!(dir, ns, "(defn answer [] 42)")

    # Precondition: without the path it is genuinely unreachable. Without
    # this assertion the test could pass on a loader that searches /tmp.
    assert_raise RuntimeError, ~r/namespace not found/, fn ->
      Loader.ensure_loaded(ns)
    end

    Env.add_search_path(dir)
    assert :ok = Loader.ensure_loaded(ns)
    assert 42 == BeamLisp.Compiler.eval_string("(#{ns}/answer)")

    File.rm_rf!(dir)
  end

  test "BEAM_LISP_PATH resolves the same way, colon-separated" do
    base = Path.join(System.tmp_dir!(), "blpath_env_#{System.unique_integer([:positive])}")
    a = Path.join(base, "a")
    b = Path.join(base, "b")
    ns_a = uniq_ns("lptest_a")
    ns_b = uniq_ns("lptest_b")
    write_ns!(a, ns_a, "(defn who [] :from_a)")
    write_ns!(b, ns_b, "(defn who [] :from_b)")

    System.put_env("BEAM_LISP_PATH", "#{a}:#{b}")

    assert :ok = Loader.ensure_loaded(ns_a)
    assert :ok = Loader.ensure_loaded(ns_b)
    assert :from_a == BeamLisp.Compiler.eval_string("(#{ns_a}/who)")
    assert :from_b == BeamLisp.Compiler.eval_string("(#{ns_b}/who)")

    File.rm_rf!(base)
  end

  test "cwd shadows a configured path: a project file still wins" do
    # The precedence that matters most. If a configured library root could
    # outrank the project's own source, adding a path would silently change
    # which code runs — the failure mode is a test suite exercising the
    # wrong copy of a file it thinks it is editing.
    ns = uniq_ns("lptest_shadow")
    cwd_dir = Path.join(File.cwd!(), "tmp/loader_path_test")
    far_dir = Path.join(System.tmp_dir!(), "blpath_far_#{System.unique_integer([:positive])}")

    # cwd-relative candidate: the loader joins cwd with the ns path, so the
    # file must sit at cwd/<ns>.bl to be the cwd candidate.
    cwd_file = Path.join(File.cwd!(), "#{ns}.bl")
    File.write!(cwd_file, "(ns #{ns})\n(defn source [] :cwd)\n")
    write_ns!(far_dir, ns, "(defn source [] :configured)")

    Env.add_search_path(far_dir)
    assert :ok = Loader.ensure_loaded(ns)
    assert :cwd == BeamLisp.Compiler.eval_string("(#{ns}/source)")

    File.rm!(cwd_file)
    File.rm_rf!(far_dir)
    File.rm_rf!(cwd_dir)
  end

  test "a configured path shadows priv/: a shipped library can be overridden" do
    # An application must be able to replace a library priv/ ships. Asserted
    # with a UNIQUE ns planted in priv/ for the duration, never by overriding
    # a real shipped library (`optics`): namespaces load once per VM and the
    # registry is global, so shadowing a real lib would (and did) hand the
    # stub to every sibling suite that requires it, and would silently no-op
    # whenever an earlier test had already loaded the real one. A test that
    # breaks its neighbours is not evidence, it is a second bug.
    ns = uniq_ns("lptest_privoverride")
    priv_dir = Application.app_dir(:beam_lisp, "priv")
    priv_file = Path.join(priv_dir, "#{ns}.bl")
    far_dir = Path.join(System.tmp_dir!(), "blpath_override_#{System.unique_integer([:positive])}")

    File.write!(priv_file, "(ns #{ns})\n(defn source [] :priv)\n")
    write_ns!(far_dir, ns, "(defn source [] :configured)")

    try do
      Env.add_search_path(far_dir)
      assert :ok = Loader.ensure_loaded(ns)
      assert :configured == BeamLisp.Compiler.eval_string("(#{ns}/source)")
    after
      File.rm(priv_file)
      File.rm_rf!(far_dir)
    end
  end

  test "priv/ still serves a ns no configured path claims" do
    # The other half of the precedence claim: adding a search path must not
    # DISPLACE priv for namespaces it does not define. Without this, a passing
    # override test is consistent with a loader that simply stopped consulting
    # priv at all.
    ns = uniq_ns("lptest_privonly")
    priv_dir = Application.app_dir(:beam_lisp, "priv")
    priv_file = Path.join(priv_dir, "#{ns}.bl")
    far_dir = Path.join(System.tmp_dir!(), "blpath_privonly_#{System.unique_integer([:positive])}")
    File.mkdir_p!(far_dir)
    File.write!(priv_file, "(ns #{ns})\n(defn source [] :priv)\n")

    try do
      Env.add_search_path(far_dir)
      assert :ok = Loader.ensure_loaded(ns)
      assert :priv == BeamLisp.Compiler.eval_string("(#{ns}/source)")
    after
      File.rm(priv_file)
      File.rm_rf!(far_dir)
    end
  end

  test "search paths are ambient: they survive a completed nested load" do
    # The distinction from load_paths (a stack popped after each load). If
    # search paths were pushed onto that stack, the first completed require
    # would drop them and the SECOND require would fail — a bug that only
    # shows up on the second call, which is why it is asserted explicitly.
    dir = Path.join(System.tmp_dir!(), "blpath_ambient_#{System.unique_integer([:positive])}")
    first = uniq_ns("lptest_first")
    second = uniq_ns("lptest_second")
    write_ns!(dir, first, "(defn v [] 1)")
    write_ns!(dir, second, "(defn v [] 2)")

    Env.add_search_path(dir)
    assert :ok = Loader.ensure_loaded(first)
    assert :ok = Loader.ensure_loaded(second)
    assert 2 == BeamLisp.Compiler.eval_string("(#{second}/v)")

    File.rm_rf!(dir)
  end

  test "add_search_path is idempotent and order-preserving" do
    Env.clear_search_paths()
    Env.add_search_path("/tmp/one")
    Env.add_search_path("/tmp/two")
    Env.add_search_path("/tmp/one")

    assert ["/tmp/one", "/tmp/two"] == Env.search_paths()
  end
end
