defmodule BeamLisp.TestRT do
  @moduledoc """
  The test registry for beam-lisp's self-hosted suite.

  `priv/std/test.bl` defines the `deftest`/`is`/`testing`/`are`/`run-tests`
  surface; the storage behind it lives here, in the shared
  `:beam_lisp_vars` ETS table (owned by `BeamLisp.Env`), so registered
  tests survive across files and runs without a supervised process.

  Run state is per-namespace but executed sequentially: `run_ns/1`
  resets the counters, runs each registered fn, and records
  per-assertion reports. The "current test" context (test name plus
  the `testing` string stack) is a single slot because tests never
  interleave.
  """

  alias BeamLisp.{Compiler, Env, RT, Vector}

  # registry: {:test_registry, ns} -> [{name, fn}]   (per env — exact-env
  # reads: a forked suite runs only ITS registered tests, never the base's)
  # run state: {:test_run, ns}     -> %{tests:, pass:, fail:, error:, reports: []}
  # current context: {:test_ctx}   -> %{ns:, test:, context: [str]}

  # --- symbol datum helpers (used at macro-expansion time) ---

  @doc "The name of a symbol datum `{:symbol, name}`, or nil."
  def sym_name({:symbol, name}), do: name
  def sym_name(_), do: nil

  @doc "True when `form` is a three-element `(= a b)` datum."
  def eq_form?([{:symbol, "="}, _, _]), do: true
  def eq_form?(_), do: false

  # --- registry ---

  @doc "Register a zero-arg test fn by ns+name; redefinition replaces."
  def register_test(ns, name, f) do
    key = {:test_registry, ns}

    tests =
      case Env.lookup_own(key) do
        {:ok, t} -> Enum.reject(t, fn {n, _} -> n == name end)
        :error -> []
      end

    Env.put_key(key, tests ++ [{name, f}])
    :ok
  end

  @doc "Registered `[{name, fn}]` for `ns`, in definition order."
  def registered_tests(ns) do
    case Env.lookup_own({:test_registry, ns}) do
      {:ok, t} -> t
      :error -> []
    end
  end

  @doc "Substitute argv symbol datums with their row value datums throughout `expr` (for `are`)."
  def subst(argv, row, expr) do
    argv = unwrap(argv)
    row = unwrap(row)
    pairs = Enum.zip(argv, row)
    walk(expr, Map.new(pairs))
  end

  defp unwrap(%Vector{} = v), do: Vector.to_list(v)
  defp unwrap(x), do: x

  defp walk({:symbol, _} = s, m), do: Map.get(m, s, s)
  defp walk(l, m) when is_list(l), do: Enum.map(l, &walk(&1, m))
  defp walk(%Vector{} = v, m), do: Vector.new(Enum.map(Vector.to_list(v), &walk(&1, m)))
  # is_map-ok: walk traverses the test-data substitution map itself; any
  # struct value in test data is a data element to walk, not a collection op.
  defp walk(mm, m) when is_map(mm), do: Map.new(mm, fn {k, v} -> {walk(k, m), walk(v, m)} end)
  defp walk(x, _m), do: x

  @doc "Drop every registered test (used to isolate ExUnit runs of run_suite/1)."
  def clear_registry do
    Env.match_delete_own({{:test_registry, :_}, :_})
    :ok
  end

  @doc "Namespaces that have registered tests, in first-registration order."
  def test_namespaces do
    # `match/2` (no limit) returns the list of matches directly.
    Env.match_own({{:test_registry, :"$1"}, :_})
    |> Enum.map(fn [ns] -> ns end)
  end

  # --- run state (PROCESS-local, not env-scoped) ---
  #
  # Counters and the current-test context belong to the PROCESS running a
  # suite, never to its env. Both run modes isolate by process (serial is
  # sequential in one process; async forks a process per file), so the
  # process dictionary is the correct home. Storing them env-prefixed was
  # a latent bug: a test body that asserts inside `(env/with-env fork …)`
  # wrote its :fail/:error record under the FORK's key, where the summary
  # — reading under the suite env — never saw it. The FAIL printed but the
  # total said 0. (The registry above stays env-scoped: a forked suite
  # must run only ITS registered tests.)

  defp run_key(ns), do: {:test_run, ns}

  defp fetch_run(ns) do
    case Process.get(run_key(ns)) do
      nil -> %{tests: 0, pass: 0, fail: 0, error: 0, reports: []}
      r -> r
    end
  end

  defp fetch_ctx do
    case Process.get(:test_ctx) do
      nil -> %{ns: nil, test: nil, context: []}
      c -> c
    end
  end

  @doc "Clear `ns`'s counters and reports before a run."
  def reset_run(ns) do
    Process.put(run_key(ns), %{tests: 0, pass: 0, fail: 0, error: 0, reports: []})
    :ok
  end

  @doc "Mark `name` (of `ns`) as the test currently executing; increments the test count."
  def begin_test(ns, name) do
    run = Map.update!(fetch_run(ns), :tests, &(&1 + 1))
    Process.put(run_key(ns), run)
    Process.put(:test_ctx, %{ns: ns, test: name, context: []})
    :ok
  end

  @doc "End the current test and clear the context slot."
  def end_test(ns) do
    Process.put(:test_ctx, %{ns: ns, test: nil, context: []})
    :ok
  end

  @doc "Run `f` with `str` pushed onto the current `testing` context."
  def with_context(str, f) do
    ctx = fetch_ctx()
    Process.put(:test_ctx, %{ctx | context: ctx.context ++ [str]})

    try do
      RT.invoke(f, [])
    after
      ctx = fetch_ctx()
      Process.put(:test_ctx, %{ctx | context: Enum.drop(ctx.context, -1)})
    end
  end

  @doc """
  Record one assertion result: bump the counter, store a report, and
  print failure/error detail immediately. Returns the `type`.
  """
  def record(ns, type, form, msg, expected, actual) do
    ctx = fetch_ctx()

    report = %{
      type: type,
      ns: ns,
      test: ctx.test,
      context: Enum.join(ctx.context, "\n"),
      form: form,
      msg: msg,
      expected: expected,
      actual: actual
    }

    run = fetch_run(ns)
    run = Map.update!(run, type, &(&1 + 1))
    Process.put(run_key(ns), %{run | reports: run.reports ++ [report]})

    if type in [:fail, :error], do: print_report(report)
    type
  end

  @doc "Run all registered tests in `ns`, printing the ns header. Returns the results map."
  def run_ns(ns) do
    reset_run(ns)
    IO.puts("\nTesting #{ns}")

    # Each test thunk belongs to `ns`: run the batch with current_ns bound
    # to it. Anything that consults the executing namespace (the query
    # engine's predicate resolution) must see the test's own ns, not
    # whatever file happened to load last.
    Env.with_ns(to_string(ns), fn ->
      Enum.each(registered_tests(ns), fn {name, f} ->
        begin_test(ns, name)

        try do
          RT.invoke(f, [])
        rescue
          e -> record(ns, :error, name, nil, name, e)
        catch
          kind, value -> record(ns, :error, name, nil, name, {kind, value})
        after
          end_test(ns)
        end
      end)
    end)

    Map.put(fetch_run(ns), :ns, ns)
  end

  @doc "Sum two suite totals maps — the shape multi-pass runners need."
  def merge_totals(a, b) do
    Map.merge(a, b, fn
      k, x, y when k in [:tests, :pass, :fail, :error] -> x + y
      _k, x, _y -> x
    end)
  end

  @doc "Sum a list of per-ns results into one totals map."
  def aggregate(results) do
    Enum.reduce(results, %{tests: 0, pass: 0, fail: 0, error: 0}, fn r, acc ->
      %{
        tests: acc.tests + r.tests,
        pass: acc.pass + r.pass,
        fail: acc.fail + r.fail,
        error: acc.error + r.error
      }
    end)
  end

  @doc "Print the clojure.test-shaped summary line."
  def print_summary(totals) do
    assertions = totals.pass + totals.fail + totals.error
    IO.puts("\nRan #{totals.tests} tests containing #{assertions} assertions.")
    IO.puts("#{totals.fail} failures, #{totals.error} errors.")
  end

  @doc """
  Load and run a beam-lisp test suite: prelude, the `priv/std/test.bl`
  library, then each `path`, then every registered namespace via the
  beam-lisp `run-tests` fn. Returns the grand totals map.

  With `async: true` (PLAN-046 L3b), the test library loads once into a
  warm base env and each FILE runs in its own fork of it, concurrently
  (capped at `System.schedulers_online/0`): per-env registries mean a
  fork's `run-tests` runs only that file's tests, and per-file output is
  buffered through a StringIO group leader so concurrent runs never
  interleave a FAIL report with another file's header. Namespaces within
  one file stay sequential — the `testing` context stack is a per-ns
  single slot by design.
  """
  def run_suite(paths, opts \\ []) do
    if Keyword.get(opts, :async, false) do
      run_suite_async(paths)
    else
      run_suite_serial(paths)
    end
  end

  defp run_suite_serial(paths) do
    BeamLisp.init()
    Compiler.eval_string(test_lib(), Compiler.new_env("core"))

    Enum.each(paths, fn path ->
      Env.in_ns("user")

      BeamLisp.Loader.with_load_path(Path.dirname(path), fn ->
        Compiler.eval_string(File.read!(path))
      end)
    end)

    RT.invoke(Env.fetch!("core", "run-tests"), [:all])
  end

  defp run_suite_async(paths) do
    BeamLisp.init()
    base = Env.fork(:global)

    Env.with_env(base, fn ->
      Compiler.eval_string(test_lib(), Compiler.new_env("core"))
    end)

    # Streams in the ORIGINAL path order so output reads like the serial
    # run's; concurrency happens inside, ordered output outside.
    results =
      Task.async_stream(
        paths,
        fn path -> {path, run_file_isolated(base, path)} end,
        max_concurrency: System.schedulers_online(),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, r} -> r end)

    Enum.each(results, fn {_path, {_totals, output}} -> IO.write(output) end)

    totals =
      results
      |> Enum.map(fn {_path, {totals, _output}} -> totals end)
      |> aggregate()

    print_summary(totals)
    totals
  end

  # One file in its own fork of the base: eval its source, run ITS tests
  # (the registry is exact-env, so the base's registrations never re-run),
  # and capture all printed output for ordered replay by the caller.
  defp run_file_isolated(base, path) do
    Env.isolated(base, fn ->
      {:ok, io} = StringIO.open("")
      prev_gl = Process.group_leader()
      :erlang.group_leader(io, self())

      try do
        Env.in_ns("user")

        BeamLisp.Loader.with_load_path(Path.dirname(path), fn ->
          Compiler.eval_string(File.read!(path))
        end)

        totals = RT.invoke(Env.fetch!("core", "run-tests"), [:all])
        {totals, StringIO.contents(io) |> elem(1)}
      after
        :erlang.group_leader(prev_gl, self())
        StringIO.close(io)
      end
    end)
  end

  @doc "True when a totals map has no failures or errors."
  def passed?(totals), do: totals.fail == 0 and totals.error == 0

  @doc "The mix task entry: run the suite and exit non-zero on any failure/error."
  def cli(paths, opts \\ []) do
    totals = run_suite(paths, opts)
    unless passed?(totals), do: System.halt(1)
  end

  # The test library ships INSIDE the compiled module, not as a runtime
  # priv file — the same rule as the prelude in beam_lisp.ex: escripts
  # (and flat .beam deployments) have no :code.priv_dir/1, so a runtime
  # File.read! would crash `bl test`. @external_resource keeps Mix
  # recompiling when the source changes.
  @test_lib_path Path.join(__DIR__, "../../priv/std/test.bl")
  @external_resource @test_lib_path
  @test_lib File.read!(@test_lib_path)

  defp test_lib, do: @test_lib

  @doc "The embedded test-library source — for in-language loaders (reload/ward.bl) " <>
       "that must work where :code.priv_dir/1 does not (escripts)."
  def test_lib_source, do: @test_lib

  # --- failure printing ---

  defp print_report(%{type: :fail} = r) do
    IO.puts("")
    IO.puts("FAIL in (#{r.ns})")
    IO.puts("  #{r.test}#{suffix(r)}")
    IO.puts("")
    IO.puts("expected: #{fmt(r.expected)}")
    IO.puts("  actual: #{fmt(r.actual)}")
  end

  defp print_report(%{type: :error} = r) do
    IO.puts("")
    IO.puts("ERROR in (#{r.ns})")
    IO.puts("  #{r.test}#{suffix(r)}")
    IO.puts("")
    IO.puts("expected: #{fmt(r.expected)}")
    IO.puts("  actual: #{BeamLisp.ExInfo.ex_message(r.actual)}")
  end

  # A `testing` context or an explicit message renders as an
  # indented continuation under the test name.
  defp suffix(r) do
    lines = [r.msg || "", r.context] |> Enum.reject(&(&1 == "" or is_nil(&1)))
    if lines == [], do: "", else: "\n" <> Enum.map_join(lines, "\n", &"  #{&1}")
  end

  defp fmt(x), do: RT.print_str(x)
end
