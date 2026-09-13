defmodule BeamLisp.BuildReleaseTest do
  @moduledoc """
  The release VALUE: what a release must carry, derived from the running VM.

  A tree is the next step (and the wave's real gate), but the value is what the
  tree is built FROM, and it is where the quiet mistakes live: an app missing
  from the closure is a boot that dies on a dependency, an extra one is a
  permanent app that must start, and a version that disagrees with the `.app`
  file is a `systools` rejection. So this suite pins the derivation against the
  one thing that cannot be argued with — Erlang's own parser reading the `.rel`
  we write back.
  """
  use ExUnit.Case, async: false

  setup do
    BeamLisp.init()
    :ok
  end

  test "the app closure is the transitive :applications closure of the root" do
    closure = bl(BeamLisp.Release.app_closure(:beam_lisp))
    assert is_list(closure)

    # `beam_lisp` requires OTP and its deps; whatever else it requires must be
    # IN the closure, and nothing in the closure may be there without a path
    # from the root.
    assert :kernel in closure and :stdlib in closure
    assert :beam_lisp in closure
    assert :elixir in closure

    # Nothing is repeated, and every app's own requirements are also present.
    assert closure == Enum.uniq(closure)

    for app <- closure, req <- Application.spec(app, :applications) || [] do
      assert req in closure, "#{app} requires #{req}, which is not in the closure"
    end
  end

  test "the value names every app with the version systools will compare" do
    value = BeamLisp.Release.value(:beam_lisp)

    assert value.name == "beam_lisp"
    assert is_binary(value.vsn) and value.vsn != ""
    assert is_binary(value.erts.vsn) and value.erts.vsn == to_string(:erlang.system_info(:version))

    apps = bl(BeamLisp.Release.value(:beam_lisp).apps)
    assert length(apps) >= 25, "expected the dependency closure, got #{length(apps)}"

    for %{app: app, vsn: vsn, dir: dir} <- apps do
      assert is_binary(vsn) and vsn != "", "#{app} has no version"
      assert File.dir?(dir), "#{app}'s directory does not exist: #{dir}"
      # The version in the value is the one the `.app` file declares — that is
      # what `systools` compares a `.rel` against.
      assert vsn == to_string(Application.spec(app, :vsn)), "#{app} version disagrees with its .app"
    end

    # One app, one entry: a duplicate would be written into the `.rel` twice.
    assert Enum.map(apps, & &1.app) == Enum.uniq(Enum.map(apps, & &1.app))
  end

  test "the .rel we write is a release term Erlang itself parses" do
    value = BeamLisp.Release.value(:beam_lisp)
    out = Path.join(System.tmp_dir!(), "beam_lisp_release_value")
    File.rm_rf!(out)

    path = BeamLisp.Release.write_rel!(value, out)
    assert path == Path.join([out, "releases", value.vsn, "beam_lisp.rel"])
    assert File.exists?(path)

    text = File.read!(path)
    assert {:ok, tokens, _} = :erl_scan.string(String.to_charlist(text))
    assert {:ok, term} = :erl_parse.parse_term(tokens)

    # The shape `systools` requires, read back by Erlang's own parser.
    assert {:release, {name, vsn}, {:erts, erts}, app_terms} = term
    assert to_string(name) == value.name
    assert to_string(vsn) == value.vsn
    assert to_string(erts) == value.erts.vsn

    # Every app in the term is one the value named, with the same version and a
    # boot TYPE — the round trip through Erlang's parser is the assertion, not
    # the string.
    assert List.keysort(List.wrap(app_terms), 0) ==
             value.apps
             |> Enum.map(&{&1.app, to_charlist(&1.vsn), :permanent})
             |> Enum.sort()

    assert String.contains?(text, "beam_lisp"), "the .rel must name the apps"
  end

  # ── the tree ───────────────────────────────────────────────────────────────
  #
  # Assembled ONCE for the module (it copies the whole dependency closure), then
  # inspected and BOOTED. The boot is the wave's gate: a tree is only a release
  # if the release runs.

  @out Path.join(System.tmp_dir!(), "beam_lisp_release_tree")

  setup_all do
    BeamLisp.init()
    File.rm_rf!(@out)
    value = BeamLisp.Release.value(:beam_lisp)
    {:ok, value: value, result: BeamLisp.Release.assemble(value, @out)}
  end

  test "the tree has what a release needs, and nothing it does not", %{value: value, result: r} do
    assert r.ok? == true, "assembly reported: #{inspect(bl(r.errors))}"
    assert r.apps == length(bl(value.apps))
    assert bl(r.errors) == []
    # systools validated the .rel against the tree; its warnings are about the
    # apps' own code (an undefined function, say), not about the assembly.
    assert is_integer(r.warnings)

    rel = Path.join([@out, "releases", value.vsn])

    for f <- [
          "beam_lisp.rel",
          "start_clean.rel",
          "beam_lisp.script",
          "beam_lisp.boot",
          "start_clean.script",
          "start_clean.boot",
          "elixir",
          "iex",
          "sys.config",
          "vm.args",
          "remote.vm.args",
          "env.sh"
        ] do
      assert File.exists?(Path.join(rel, f)), "missing releases/<vsn>/#{f}"
    end

    for f <- ["bin/bl", "releases/COOKIE", "releases/start_erl.data"] do
      assert File.exists?(Path.join(@out, f)), "missing #{f}"
    end

    # ERTS: the `erl` the patched Elixir wrapper execs.
    assert File.exists?(Path.join([@out, "erts-#{value.erts.vsn}", "bin", "erl"]))

    # Every app is present as `<app>-<vsn>/ebin/<app>.app` — the shape systools
    # walked to accept the .rel, so one passing assembly proves it for all of
    # them.
    for app <- bl(value.apps) do
      assert File.exists?(
               Path.join([@out, "lib", "#{app.app}-#{app.vsn}", "ebin", "#{app.app}.app"])
             )
    end

    # The two substitutions in the Elixir wrapper: ERTS is release-relative, and
    # the host's `-elixir_root/-pa` pair is gone.
    wrapper = File.read!(Path.join(rel, "elixir"))
    assert wrapper =~ ~s|ERTS_BIN="$SCRIPT_PATH"/../../erts-#{value.erts.vsn}/bin/|
    refute wrapper =~ "-elixir_root"

    # The rewrite happened BEFORE script2boot, so the paths are already
    # release-relative in both the script and the COMPILED boot file.
    assert File.read!(Path.join(rel, "beam_lisp.script")) =~ "$RELEASE_LIB"
    refute File.read!(Path.join(rel, "beam_lisp.script")) =~ "$ROOT/lib"
    refute File.read!(Path.join(rel, "beam_lisp.boot")) =~ "$ROOT/lib"

    # Byte-for-byte what a mix release writes: no trailing newline, and the
    # launcher's `cut -d' ' -f2` reads it either way.
    assert File.read!(Path.join(@out, "releases/start_erl.data")) ==
             "#{value.erts.vsn} #{value.vsn}"

    refute File.exists?(Path.join([@out, "lib", "beam_lisp-0.1.0", "priv", ".spell"])),
           "editor state must not be packaged"
  end

  test "the gate: the tree boots, and the language runs in it", %{result: r} do
    assert r.ok? == true, "assembly reported: #{inspect(bl(r.errors))}"
    launcher = Path.join(@out, "bin/bl")

    # `eval` boots `start_clean`: the release's code is on the path and nothing
    # is started. This is the gate — a tree is only a release if it runs.
    {out, code} = System.cmd(launcher, ["eval", ~s|IO.puts("BOOT " <> System.version())|], stderr_to_stdout: true)
    assert code == 0, "eval exited #{code}:\n#{out}"
    assert out =~ "BOOT 1.20", "eval printed: #{out}"

    # …and the LANGUAGE runs in it, through a launcher that generated every
    # piece of the tree itself (the same invocation W0's hand-assembled probe
    # used, where all of it came from a shipped payload).
    {out, code} =
      System.cmd(launcher, ["eval", ~s|BeamLisp.Ns.Bl.Cli.main(["eval","(+ 40 2)"])|],
        stderr_to_stdout: true
      )

    assert code == 0, "language eval exited #{code}:\n#{out}"
    assert out =~ "42", "language eval printed: #{out}"

    {out, code} = System.cmd(launcher, ["version"], stderr_to_stdout: true)
    assert code == 0
    assert out =~ "beam_lisp"
  end

  # The language's collections cross back as host structs: a `Vector` is not an
  # Elixir list, so normalise at the boundary rather than loosening the shape.
  defp bl(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp bl(list) when is_list(list), do: list
  defp bl(other), do: other
end
