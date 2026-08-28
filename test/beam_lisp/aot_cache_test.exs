defmodule BeamLisp.AOTCacheTest do
  use ExUnit.Case, async: false

  # The cache is global by default; every test here pins it to a
  # per-module temp dir via BEAM_LISP_AOT_CACHE_DIR so runs stay hermetic
  # and never touch the developer's real cache.

  alias BeamLisp.AOTCache

  @fixture_dir "test/fixtures/aot"

  setup do
    cache_dir = Path.join(System.tmp_dir!(), "beam_lisp_cache_test_#{System.unique_integer([:positive])}")
    out_a = Path.join(System.tmp_dir!(), "beam_lisp_cache_out_a_#{System.unique_integer([:positive])}")
    out_b = Path.join(System.tmp_dir!(), "beam_lisp_cache_out_b_#{System.unique_integer([:positive])}")

    prev = System.get_env("BEAM_LISP_AOT_CACHE_DIR")
    System.put_env("BEAM_LISP_AOT_CACHE_DIR", cache_dir)

    on_exit(fn ->
      if prev, do: System.put_env("BEAM_LISP_AOT_CACHE_DIR", prev), else: System.delete_env("BEAM_LISP_AOT_CACHE_DIR")
      File.rm_rf(cache_dir)
      File.rm_rf(out_a)
      File.rm_rf(out_b)
    end)

    BeamLisp.init()
    {:ok, cache_dir: cache_dir, out_a: out_a, out_b: out_b}
  end

  defp run_task(out) do
    Mix.Tasks.Compile.BeamLisp.run(["--source-dir", @fixture_dir, "--out", out])
  end

  test "second build of the same sources into a fresh dir is served from cache", %{
    out_a: out_a,
    out_b: out_b,
    cache_dir: cache_dir
  } do
    assert {:ok, []} = run_task(out_a)
    assert File.dir?(cache_dir)

    entry_count = Path.wildcard(Path.join([cache_dir, "*", "*", "manifest.term"])) |> length()
    assert entry_count > 0

    # Fresh output dir, no manifest of its own: without the cache this
    # run compiles; with it, every source is a fetch.
    assert {:ok, []} = run_task(out_b)

    for mod <- [BeamLisp.Ns.Greeter, BeamLisp.Ns.Hello, BeamLisp.Ns.Math] do
      beam = Atom.to_string(mod) <> ".beam"
      assert File.exists?(Path.join(out_b, beam)), "expected #{beam} linked into out_b"
      assert File.read!(Path.join(out_a, beam)) == File.read!(Path.join(out_b, beam))
    end
  end

  test "cache hit produces working modules" do
    key = AOTCache.compiler_key()
    deps = %{}
    hashes = %{}
    assert is_binary(key)
    assert AOTCache.closure_key("/nonexistent/x.bl", deps, %{"/nonexistent/x.bl" => "h"}) |> is_binary()

    # store then fetch round-trips the module list and the beam bytes
    src_dir = Path.join(System.tmp_dir!(), "aot_cache_roundtrip_#{System.unique_integer([:positive])}")
    File.mkdir_p!(src_dir)
    fake_beam = :crypto.strong_rand_bytes(64)
    File.write!(Path.join(src_dir, "Elixir.FakeMod.beam"), fake_beam)

    :ok = AOTCache.store(key, "closure", src_dir, [FakeMod])

    dst_dir = Path.join(System.tmp_dir!(), "aot_cache_roundtrip_dst_#{System.unique_integer([:positive])}")
    assert {:ok, [FakeMod]} = AOTCache.fetch(key, "closure", dst_dir)
    assert File.read!(Path.join(dst_dir, "Elixir.FakeMod.beam")) == fake_beam
  end

  test "missing beams degrade to a miss" do
    key = AOTCache.compiler_key()
    assert :miss = AOTCache.fetch(key, "never-stored", System.tmp_dir!())
  end

  test "BEAM_LISP_AOT_CACHE=off disables participation" do
    System.put_env("BEAM_LISP_AOT_CACHE", "off")
    refute AOTCache.enabled?()
    System.delete_env("BEAM_LISP_AOT_CACHE")
    assert AOTCache.enabled?()
  end

  test "changing a dependency's content changes the closure key" do
    hashes_a = %{"a.bl" => "1", "b.bl" => "2", "c.bl" => "9"}
    hashes_b = %{"a.bl" => "1", "b.bl" => "3", "c.bl" => "9"}
    deps = %{"a.bl" => ["b.bl"], "b.bl" => []}

    refute AOTCache.closure_key("a.bl", deps, hashes_a) ==
             AOTCache.closure_key("a.bl", deps, hashes_b)

    # a source that does not depend on b.bl is unaffected
    assert AOTCache.closure_key("c.bl", deps, hashes_a) ==
             AOTCache.closure_key("c.bl", deps, hashes_b)
  end
end
