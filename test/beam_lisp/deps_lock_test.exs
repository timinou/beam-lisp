defmodule BeamLisp.DepsLockTest do
  @moduledoc """
  `bl.lock` — the Mix-free lock — against `mix.lock`, the one Mix wrote.

  The conversion is a change of FILE FORMAT, not a re-resolution: same names,
  same versions, same tarball digests. A conversion that drifted silently would
  be a lie about what a build installs, and nothing else in the tree would
  notice, so it is pinned here.

  WHICH digest is pinned matters, and the first version got it wrong in a way
  this test could not see because it made the same mistake: `mix.lock` carries
  TWO, and the 4th field is hex's deprecated INNER checksum (the value of the
  `CHECKSUM` file inside the tarball), while the 8th is sha256 of the tarball as
  served — what `bl deps fetch` downloads, hashes, and must compare against.
  Measured on toml 0.7.0: 4th = fbcd773c…, 8th = 0690246a…, and neither is
  sha256 of contents.tar.gz (that is a third value, 8cf00edd…). Comparing `bl.lock`
  against the wrong field is how the fetcher came to refuse all 47 real packages
  while its own suite stayed green. So this test compares field 8.

  When `mix.lock` is eventually deleted (the toolchain does not need it; the
  dependency PROVISIONING path still does — 44 of the 47 packages build with
  `mix`, 3 with `rebar3`, so a Mix-free fetch-and-compile is its own piece of
  work), this test stops comparing and starts asserting that `bl.lock` is the
  only truth and is still whole.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  test "bl.lock names the same deps, with the same digests, as mix.lock" do
    bl = parse_bl!(Path.join(@root, "bl.lock"))
    assert map_size(bl) >= 40, "the lock is the resolved closure, not a sample"

    mix_path = Path.join(@root, "mix.lock")

    if File.exists?(mix_path) do
      assert bl == parse_mix!(mix_path),
             "bl.lock and mix.lock disagree — one of them lies about what a build installs"
    else
      assert Enum.all?(bl, fn {_name, {vsn, sha}} ->
               is_binary(vsn) and vsn != "" and byte_size(sha) == 64
             end)
    end
  end

  test "every entry names a source this tree can act on" do
    for {name, {vsn, sha}} <- parse_bl!(Path.join(@root, "bl.lock")) do
      assert is_binary(name) and name != ""
      assert is_binary(vsn) and vsn != ""
      assert sha =~ ~r/^[0-9a-f]{64}$/, "#{name} #{vsn} has a digest that is not a sha256"
    end
  end

  defp parse_bl!(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ";")))
    |> Map.new(fn line ->
      case String.split(line, " ") do
        ["[:dep", name, vsn, sha, "hex]"] -> {name, {vsn, sha}}
        other -> flunk("unreadable lock line: #{inspect(other)}")
      end
    end)
  end

  defp parse_mix!(path) do
    {map, _} = Code.eval_file(path)

    Map.new(map, fn {name, entry} ->
      {:hex, _name, vsn, _inner, _tools, _deps, _repo, outer} = entry
      {to_string(name), {vsn, outer}}
    end)
  end
end
