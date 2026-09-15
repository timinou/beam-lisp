defmodule BeamLisp.DepsCompileTest do
  @moduledoc """
  `bl deps compile` — FUP-050's step 1: what a lock NAMES becomes a library that
  can be loaded, with no Mix anywhere in the path.

  Five properties, each because getting it wrong is silent:

    * a package's sources compile into a directory addressed by content, and its
      `.app` file CONSULTS — a term file nobody can read is not an application,
      and the failure would surface as a missing app two stages later;
    * `priv/` arrives next to `ebin`, which is where OTP looks for it;
    * the marker appears only after a successful compile, so a directory a build
      died in is redone rather than trusted;
    * a second run is `:cached`, because a library that recompiles on every
      build is not a cache;
    * a package that cannot compile is REPORTED with the compiler's own message
      and does not end the run — 47 packages are compiled in a loop, and any one
      of them can be wrong.
  """
  use ExUnit.Case, async: false

  setup do
    BeamLisp.init()
    cache =
      Path.join(
        System.tmp_dir!(),
        "bl_deps_compile_#{System.pid()}_#{:erlang.unique_integer([:positive])}"
      )

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

  defp list(v), do: BeamLisp.Vector.to_list(v)

  # A package as `hex/install!` leaves one: its sources under the content
  # address, and the digest beside them.
  defp store_package!(cache, name, vsn, sha, files) do
    dir = Path.join([cache, "beam_lisp", "lib", "#{name}-#{vsn}-#{String.slice(sha, 0, 8)}"])

    for {rel, body} <- files do
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end

    File.write!(Path.join(dir, ".hex-sha"), sha)
    dir
  end

  defp sha(seed), do: String.duplicate(seed, 64) |> String.slice(0, 64)

  defp lock!(dir, entries) do
    call("deps", "write-lock!", [
      dir,
      Enum.map(entries, fn {name, vsn, sha} ->
        %{name: name, vsn: vsn, sha: sha, source: :hex}
      end)
    ])
  end

  defp compile!(dir) do
    r = call("deps-compile", "compile!", [dir, 60_000, nil])
    %{
      ok?: r[:ok?],
      passes: r[:passes],
      results: list(r[:results]),
      by_name: Map.new(list(r[:results]), fn x -> {x[:name], x} end)
    }
  end

  @elixir_pkg [
    {"mix.exs",
     """
     defmodule Thing.MixProject do
       use Mix.Project

       def project, do: [app: :thing, version: "0.1.0"]
       def application, do: [extra_applications: [:logger]]
     end
     """},
    {"lib/thing.ex", "defmodule Thing do\n  def answer, do: 42\nend\n"},
    {"priv/data.txt", "the library's data directory\n"}
  ]

  @erlang_pkg [
    {"src/thing_erl.app.src",
     "{application, thing_erl, [{vsn, \"0.2.0\"}, {applications, [kernel, stdlib]}]}.\n"},
    {"src/thing_erl.erl", "-module(thing_erl).\n-export([answer/0]).\nanswer() -> 42.\n"}
  ]

  test "an Elixir package compiles into a content-addressed directory with a readable .app",
       %{cache: cache} do
    d = sha("a")
    store_package!(cache, "thing", "0.1.0", d, @elixir_pkg)

    proj = Path.join(cache, "proj")
    File.mkdir_p!(proj)
    lock!(proj, [{"thing", "0.1.0", d}])

    r = compile!(proj)
    assert r.ok?, "compile refused: #{inspect(r.results)}"
    assert r.by_name["thing"][:state] == :compiled
    assert r.by_name["thing"][:modules] == 1

    # the address is content AND runtime
    rt = call("deps-compile", "runtime-tag", [])
    app_dir = Path.join([cache, "beam_lisp", "ebin", "thing-0.1.0-#{String.slice(d, 0, 8)}-#{rt}"])
    assert File.dir?(app_dir), "expected #{app_dir}"

    # the beams
    assert File.exists?(Path.join(app_dir, "ebin/Elixir.Thing.beam"))

    # the .app CONSULTS — that is the property, not that a file exists
    app = Path.join(app_dir, "ebin/thing.app")
    assert {:ok, [term]} = :file.consult(String.to_charlist(app))
    assert {:application, :thing, props} = term
    assert Enum.any?(props, fn {k, v} -> k == :modules and v == [Thing] end),
           "the modules list must be an Erlang list of atoms, got #{inspect(props[:modules])}"
    assert Enum.any?(props, fn {k, v} -> k == :applications and :logger in v end)

    # priv/ is beside ebin, which is where OTP finds it
    assert File.exists?(Path.join(app_dir, "priv/data.txt"))
  end

  test "a second run is :cached, and a broken package is reported without ending the run",
       %{cache: cache} do
    good = sha("b")
    bad = sha("c")
    store_package!(cache, "good", "0.1.0", good, @elixir_pkg)
    store_package!(cache, "broken", "0.1.0", bad, [
      {"mix.exs", "defmodule Broken.MixProject do\n  def project, do: [app: :broken, version: \"0.1.0\"]\nend\n"},
      {"lib/broken.ex", "defmodule Broken do\n  def broken do\nend\n"}
    ])

    proj = Path.join(cache, "proj2")
    File.mkdir_p!(proj)
    lock!(proj, [{"good", "0.1.0", good}, {"broken", "0.1.0", bad}])

    r = compile!(proj)
    refute r.ok?, "a package that will not compile must make the run report failure"
    assert r.by_name["good"][:state] == :compiled
    assert r.by_name["broken"][:state] == :failed
    assert is_binary(r.by_name["broken"][:why]),
           "a failure must carry a reason, got #{inspect(r.by_name["broken"])}"

    # the marker is the proof a compile FINISHED, so the broken one has none
    rt = call("deps-compile", "runtime-tag", [])
    root = Path.join([cache, "beam_lisp", "ebin"])
    assert File.exists?(Path.join([root, "good-0.1.0-#{String.slice(good, 0, 8)}-#{rt}", ".compiled"]))
    refute File.exists?(Path.join([root, "broken-0.1.0-#{String.slice(bad, 0, 8)}-#{rt}", ".compiled"]))

    # second run: the good one is cache, not work
    r2 = compile!(proj)
    assert r2.by_name["good"][:state] == :cached
    assert r2.by_name["broken"][:state] == :failed
  end

  test "an Erlang package compiles through erlc, and its .app.src is honoured", %{cache: cache} do
    d = sha("d")
    store_package!(cache, "thing_erl", "0.2.0", d, @erlang_pkg)

    proj = Path.join(cache, "proj3")
    File.mkdir_p!(proj)
    lock!(proj, [{"thing_erl", "0.2.0", d}])

    r = compile!(proj)
    assert r.ok?, "erlc path refused: #{inspect(r.results)}"
    assert r.by_name["thing_erl"][:state] == :compiled
    assert r.by_name["thing_erl"][:tool] == :erlang

    rt = call("deps-compile", "runtime-tag", [])
    app_dir = Path.join([cache, "beam_lisp", "ebin", "thing_erl-0.2.0-#{String.slice(d, 0, 8)}-#{rt}"])
    assert File.exists?(Path.join(app_dir, "ebin/thing_erl.beam"))

    assert {:ok, [term]} = :file.consult(String.to_charlist(Path.join(app_dir, "ebin/thing_erl.app")))
    assert {:application, :thing_erl, props} = term
    assert Enum.any?(props, fn {k, v} -> k == :modules and v == [:thing_erl] end)
    # the lock's version wins over the .app.src's, because the lock is the truth
    assert Enum.any?(props, fn {k, v} -> k == :vsn and to_string(v) == "0.2.0" end)
  end
end
