defmodule BeamLisp.AOTCacheGCTest do
  use ExUnit.Case, async: false

  alias BeamLisp.AOTCache

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam_lisp_cache_gc_#{System.unique_integer([:positive])}")

    outside =
      Path.join(
        System.tmp_dir!(),
        "beam_lisp_cache_gc_outside_#{System.unique_integer([:positive])}"
      )

    previous_dir = System.get_env("BEAM_LISP_AOT_CACHE_DIR")
    previous_config = Application.get_env(:beam_lisp, :aot_cache_gc)

    System.put_env("BEAM_LISP_AOT_CACHE_DIR", root)
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    AOTCache.reset_cleanup_throttle()

    on_exit(fn ->
      if previous_dir,
        do: System.put_env("BEAM_LISP_AOT_CACHE_DIR", previous_dir),
        else: System.delete_env("BEAM_LISP_AOT_CACHE_DIR")

      if previous_config,
        do: Application.put_env(:beam_lisp, :aot_cache_gc, previous_config),
        else: Application.delete_env(:beam_lisp, :aot_cache_gc)

      AOTCache.reset_cleanup_throttle()
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    {:ok, root: root, outside: outside}
  end

  test "retired backend is rejected before compilation" do
    previous = Application.get_env(:beam_lisp, :aot_backend)
    try do
      Application.put_env(:beam_lisp, :aot_backend, :elixir)
      assert_raise ArgumentError, ~r/self-hosted compiler emits ANF; use :core/, fn ->
        AOTCache.aot_backend()
      end
    after
      if previous,
        do: Application.put_env(:beam_lisp, :aot_backend, previous),
        else: Application.delete_env(:beam_lisp, :aot_backend)
    end
  end

  test "protects active generation and bounds retention cleanup", %{root: root} do
    active = key("a")
    newest = generation!(root, key("b"), days_ago: 1)
    older = generation!(root, key("c"), days_ago: 2)
    oldest = generation!(root, key("d"), days_ago: 3)
    generation!(root, active, days_ago: 100)

    assert {:ok, [deleted]} =
             AOTCache.cleanup_obsolete_generations(active,
               keep_generations: 2,
               max_age_days: 365,
               max_delete: 1
             )

    assert deleted == Path.basename(oldest)
    assert File.dir?(Path.join(root, active))
    assert File.dir?(newest)
    assert File.dir?(older)
    refute File.exists?(oldest)
  end

  test "age expiration removes old generations within the deletion cap", %{root: root} do
    active = key("a")
    old_a = generation!(root, key("b"), days_ago: 40)
    old_b = generation!(root, key("c"), days_ago: 35)
    generation!(root, active, days_ago: 100)

    assert {:ok, deleted} =
             AOTCache.cleanup_obsolete_generations(active,
               keep_generations: 10,
               max_age_days: 30,
               max_delete: 1
             )

    assert length(deleted) == 1
    assert Enum.count([old_a, old_b], &File.dir?/1) == 1
    assert File.dir?(Path.join(root, active))
  end

  test "ignores invalid names and symlinks without traversing them", %{
    root: root,
    outside: outside
  } do
    active = key("a")
    invalid = generation!(root, "not-a-compiler-key", days_ago: 100)
    target_marker = Path.join(outside, "keep")
    File.write!(target_marker, "outside")

    symlink = Path.join(root, key("b"))
    File.ln_s!(outside, symlink)
    generation!(root, active, days_ago: 100)

    assert {:ok, []} =
             AOTCache.cleanup_obsolete_generations(active,
               keep_generations: 1,
               max_age_days: 1,
               max_delete: 10
             )

    assert File.dir?(invalid)
    assert File.read!(target_marker) == "outside"
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(symlink)
  end

  test "store-triggered cleanup is throttled", %{root: root} do
    active = key("a")
    first_old = generation!(root, key("b"), days_ago: 2)
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "Elixir.FakeGC.beam"), "beam")

    Application.put_env(:beam_lisp, :aot_cache_gc,
      keep_generations: 1,
      max_age_days: 365,
      max_delete: 10,
      interval_ms: 60_000
    )

    assert :ok = AOTCache.store(active, "first", source, [FakeGC])
    refute File.exists?(first_old)

    second_old = generation!(root, key("c"), days_ago: 2)
    assert :ok = AOTCache.store(active, "second", source, [FakeGC])
    assert File.dir?(second_old)
  end

  test "parallel stores share one bounded sweep", %{root: root} do
    active = key("a")
    old = for char <- ~w(b c d e), do: generation!(root, key(char), days_ago: 40)
    source = Path.join(root, "parallel-source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "Elixir.FakeGC.beam"), "beam")

    Application.put_env(:beam_lisp, :aot_cache_gc,
      keep_generations: 1,
      max_age_days: 30,
      max_delete: 1,
      interval_ms: 60_000
    )

    results =
      1..8
      |> Task.async_stream(fn n -> AOTCache.store(active, "entry-#{n}", source, [FakeGC]) end,
        max_concurrency: 8
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert Enum.count(old, &File.dir?/1) == 3
  end

  defp key(character), do: String.duplicate(character, 64)

  defp generation!(root, name, opts) do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "marker"), name)

    seconds = System.os_time(:second) - Keyword.fetch!(opts, :days_ago) * 86_400
    datetime = seconds |> DateTime.from_unix!() |> DateTime.to_naive() |> NaiveDateTime.to_erl()
    :ok = File.touch(path, datetime)
    path
  end
end
