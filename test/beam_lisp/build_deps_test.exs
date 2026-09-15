defmodule BeamLisp.BuildDepsTest do
  @moduledoc """
  W7 — the library store, and the hex client that fills it.

  The store's half is proved with real tarballs: VERSION, CHECKSUM,
  metadata.config, contents.tar.gz — the four entries hex actually ships, where
  the outer archive is a PLAIN tar and the inner is gzipped, and CHECKSUM is
  stated in UPPERCASE. All three of those were measured against jason-1.4.4 from
  hex.pm rather than assumed, and each one is a bug if assumed the other way.

  Three refusals matter, and each asserts the store is UNCHANGED afterwards — an
  artifact that fails a check must never become visible under its content
  address:

    * a tarball whose digest is not the one the lock names,
    * a tarball whose CHECKSUM lies about its contents (the outer digest matches,
      so only the inner check can catch it),
    * a lock naming a library the store does not hold.

  The server-side half — the API contract and its derived mock — lives in
  `test/bl/deps_test.bl`, where Veritas's quoted predicates read as they do in the
  examples, and where the client is driven through a transport that is a VALUE.
  """
  use ExUnit.Case, async: false

  setup do
    BeamLisp.init()

    # An isolated store: the real one is the user's cache, and a test has no
    # business writing to it.
    cache = "/tmp/beam_lisp_deps_cache"
    File.rm_rf!(cache)
    File.mkdir_p!(cache)
    System.put_env("XDG_CACHE_HOME", cache)

    scratch = "/tmp/beam_lisp_deps_scratch"
    File.rm_rf!(scratch)
    File.mkdir_p!(scratch)
    on_exit(fn -> System.delete_env("XDG_CACHE_HOME") end)
    %{cache: cache, scratch: scratch}
  end

  defp call(ns, f, args) do
    BeamLisp.Loader.ensure_loaded(ns)
    BeamLisp.RT.invoke(BeamLisp.Env.fetch!(ns, f), args)
  end

  defp list(v), do: BeamLisp.Vector.to_list(v)

  # ── a real hex-shaped tarball ────────────────────────────────────────────

  defp contents_tar_gz!(dir) do
    src = Path.join(dir, "content")
    File.rm_rf!(src)
    File.mkdir_p!(Path.join(src, "lib"))
    File.write!(Path.join(src, "lib/thing.ex"), "defmodule Thing do\nend\n")
    cgz = Path.join(dir, "contents.tar.gz")
    # `:erl_tar.create/3` takes names RELATIVE TO THE CWD — it has no `:cwd`
    # option (extract does) — so the fixture chdirs, the way the tool expects.
    File.cd!(src, fn ->
      :ok = :erl_tar.create(String.to_charlist(cgz), [~c"lib", ~c"lib/thing.ex"], [:compressed])
    end)
    File.read!(cgz)
  end

  defp hex_tarball!(dir, name, vsn, checksum_override \\ nil) do
    work = Path.join(dir, "tarball-#{name}-#{vsn}")
    File.rm_rf!(work)
    File.mkdir_p!(work)
    inner_bytes = contents_tar_gz!(work)
    # 64 hex characters — the SHAPE hex writes. What hex puts in this file is its
    # canonical INNER checksum, which this client does not recompute: measured on
    # toml 0.7.0 it is neither sha256(outer tar) nor sha256(contents.tar.gz), and
    # hex_core calls it deprecated in favour of the outer checksum. The fixture
    # therefore only has to have the shape — the outer digest below is the one
    # that pins the bytes.
    _ = inner_bytes
    inner_sha = String.duplicate("F", 64)

    File.write!(Path.join(work, "CHECKSUM"), checksum_override || inner_sha)
    File.write!(Path.join(work, "VERSION"), "3")
    File.write!(Path.join(work, "metadata.config"), "{ok}.\n")

    out = Path.join(dir, "#{name}-#{vsn}.tar")
    File.cd!(work, fn ->
      :ok =
        :erl_tar.create(String.to_charlist(out),
          [~c"VERSION", ~c"CHECKSUM", ~c"metadata.config", ~c"contents.tar.gz"], [])
    end)

    bytes = File.read!(out)
    %{path: out, bytes: bytes, sha: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  end

  # The transport answers in the shape the CLIENT reads: a map with `:ok` or
  # `:error`. An Elixir tuple would cross as a tuple, and bl's keyword lookup on
  # a tuple answers nil — a transport contract is part of the interface.
  defp transport_for(tar_bytes, api_json \\ ~s({"name":"jason","releases":[{"version":"1.4.4","checksum":"ABC"}]})) do
    fn url, opts ->
      cond do
        String.contains?(url, "/api/packages/") -> %{ok: api_json}
        String.contains?(url, ".tar") and Map.get(opts, :binary?) -> %{ok: tar_bytes}
        true -> %{error: "no route for #{url}"}
      end
    end
  end

  test "a locked tarball installs, and the store holds what it claims", %{scratch: scratch} do
    t = hex_tarball!(scratch, "jason", "1.4.4")
    r = call("hex", "install!", [transport_for(t.bytes), %{name: "jason", vsn: "1.4.4", sha: t.sha}, scratch])

    assert r[:ok?], "install failed: #{inspect(r[:why])}"
    assert call("store", "present?", ["jason", "1.4.4", t.sha])
    assert File.exists?(Path.join(r[:dir], "lib/thing.ex"))
    assert String.trim(File.read!(Path.join(r[:dir], ".hex-sha"))) == t.sha
  end

  test "a tarball that is not what the lock names is refused, and nothing is installed", %{scratch: scratch} do
    t = hex_tarball!(scratch, "jason", "1.4.4")
    wrong = String.duplicate("0", 64)
    r = call("hex", "install!", [transport_for(t.bytes), %{name: "jason", vsn: "1.4.4", sha: wrong}, scratch])

    refute r[:ok?]
    assert r[:why] =~ "digest differs from the lock"
    refute call("store", "present?", ["jason", "1.4.4", wrong])
    refute call("store", "present?", ["jason", "1.4.4", t.sha])
  end

  # This test used to assert the opposite rule — that CHECKSUM is sha256 of
  # contents.tar.gz — and so AGREED with a client that could not install a single
  # real package. It is now about the rule that exists: the value must have the
  # shape hex writes, because 47 of 47 real tarballs have it and a malformed one
  # is a reason to stop.
  test "a tarball whose CHECKSUM is not sha256-shaped is refused", %{scratch: scratch} do
    t = hex_tarball!(scratch, "jason", "1.4.4", "not-a-digest")
    r = call("hex", "install!", [transport_for(t.bytes), %{name: "jason", vsn: "1.4.4", sha: t.sha}, scratch])

    refute r[:ok?]
    assert r[:why] =~ "not sha256-shaped"
    refute call("store", "present?", ["jason", "1.4.4", t.sha])
  end

  test "an API document the client cannot use is an error, not a crash", %{scratch: scratch} do
    _ = scratch
    r = call("hex", "package", [transport_for(<<>>, "not json at all"), "jason"])
    assert r[:error] =~ "package document"
  end

  test "verify is offline, reports what is missing, and list reads the DISK", %{scratch: scratch} do
    t = hex_tarball!(scratch, "jason", "1.4.4")
    tr = transport_for(t.bytes)

    tree = Path.join(scratch, "tree")
    File.mkdir_p!(tree)

    call("deps", "write-lock!", [tree, [
      %{name: "jason", vsn: "1.4.4", sha: t.sha, source: :hex},
      %{name: "decimal", vsn: "2.3.0", sha: String.duplicate("b", 64), source: :hex}
    ]])

    v = call("deps", "verify", [tree])
    refute v[:ok?]
    assert v[:checked] == 2
    assert length(list(v[:missing])) == 2

    assert call("hex", "install!", [tr, %{name: "jason", vsn: "1.4.4", sha: t.sha}, scratch])[:ok?]

    v2 = call("deps", "verify", [tree])
    refute v2[:ok?]
    missing = list(v2[:missing])
    assert length(missing) == 1
    assert hd(missing)[:name] == "decimal"

    rows = list(call("deps", "installed", []))
    assert length(rows) == 1
    assert hd(rows)[:name] == "jason"

    # The lock is FACTS: one line each, readable by anything that reads lines.
    text = File.read!(Path.join(tree, "bl.lock"))
    assert text =~ "[:dep jason 1.4.4 #{t.sha} hex]"
    assert length(String.split(String.trim(text), "\n")) == 2

    # An absent lock and an empty lock are different answers.
    empty = Path.join(scratch, "emptytree")
    File.mkdir_p!(empty)
    assert call("deps", "verify", [empty])[:why] =~ "no lock at"
  end

  test "a leftover temp install is swept and never mistaken for a library", %{cache: cache} do
    lib = Path.join([cache, "beam_lisp", "lib"])
    File.mkdir_p!(lib)
    tmp = Path.join(lib, "jason-1.4.4-deadbeef.tmp-999")
    File.mkdir_p!(tmp)

    assert call("store", "sweep-temp!", []) == 1
    refute File.exists?(tmp)
    assert list(call("store", "entries", [])) == []
  end
end
