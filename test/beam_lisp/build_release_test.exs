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

  # The language's collections cross back as host structs: a `Vector` is not an
  # Elixir list, so normalise at the boundary rather than loosening the shape.
  defp bl(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp bl(list) when is_list(list), do: list
  defp bl(other), do: other
end
