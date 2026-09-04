defmodule BeamLisp.Daemon.Paths do
  @moduledoc """
  Filesystem identity for a `bl` daemon: one daemon per canonical checkout /
  payload root, keyed by a short hash of that root's real path.

  Every endpoint (socket, token, pidfile, meta, start-lock) lives under a
  user-owned `0700` runtime directory. A pathname `AF_UNIX` socket has a hard
  ~108-byte limit on Linux (`sun_path`), so the runtime dir is kept short and
  the tree id is a 16-hex prefix (64 bits — collision-free in practice for a
  handful of checkouts per user).

  The socket's mere existence is NOT authority (a stale node survives a crash);
  an authenticated hello over it is. These paths are where a client LOOKS; the
  handshake is what it TRUSTS.
  """

  import Bitwise, only: [&&&: 2]

  @tree_id_len 16

  @doc """
  The canonical 16-hex tree id for `root` (a checkout dir or an extracted drop
  payload dir). `root` is realpath-resolved first so two spellings of the same
  tree share one daemon; a non-existent path hashes by its expanded form.
  """
  def tree_id(root) when is_binary(root) do
    canonical =
      case File.stat(root, time: :posix) do
        {:ok, _} -> real_path(root)
        _ -> Path.expand(root)
      end

    :crypto.hash(:sha256, canonical)
    |> Base.encode16(case: :lower)
    |> binary_part(0, @tree_id_len)
  end

  @doc """
  The 32-byte SHA-256 of `root`'s real path — the full tree fingerprint sent in
  the handshake `:tree` field (the 16-hex id is only for filenames).
  """
  def tree_fingerprint(root) when is_binary(root) do
    canonical =
      case File.stat(root) do
        {:ok, _} -> real_path(root)
        _ -> Path.expand(root)
      end

    :crypto.hash(:sha256, canonical)
  end

  @doc """
  The runtime directory holding this user's daemon endpoints, created `0700`
  with ownership + symlink guards. Prefers `$XDG_RUNTIME_DIR/beam_lisp` (a
  tmpfs the OS wipes on logout); falls back to `/tmp/beam_lisp-<uid>`.

  Returns `{:ok, dir}` or `{:error, reason}` — a caller must not proceed to
  bind a socket in a directory it could not secure.
  """
  def runtime_dir do
    base =
      case System.get_env("XDG_RUNTIME_DIR") do
        dir when is_binary(dir) and dir != "" -> Path.join(dir, "beam_lisp")
        _ -> Path.join(System.tmp_dir!(), "beam_lisp-#{current_uid()}")
      end

    with :ok <- ensure_secure_dir(base) do
      {:ok, base}
    end
  end

  @doc """
  The endpoint path set for `root`. Returns a map of absolute paths:
  `:sock` `:token` `:pid` `:meta` `:lock`. Fails if the runtime dir cannot be
  secured or the socket path would exceed the `AF_UNIX` limit.
  """
  def endpoints(root) when is_binary(root) do
    with {:ok, dir} <- runtime_dir() do
      id = tree_id(root)
      sock = Path.join(dir, "#{id}.sock")

      if byte_size(sock) > 100 do
        {:error, {:socket_path_too_long, sock}}
      else
        {:ok,
         %{
           tree_id: id,
           sock: sock,
           token: Path.join(dir, "#{id}.token"),
           pid: Path.join(dir, "#{id}.pid"),
           meta: Path.join(dir, "#{id}.meta"),
           lock: Path.join(dir, "#{id}.start")
         }}
      end
    end
  end

  @doc """
  Resolve the daemon root for a working directory: the nearest ancestor of
  `cwd` that looks like a beam-lisp tree (has `priv/boot/core.bl` or, for an
  extracted release, `bin/bl` + `releases/`). Returns `{:ok, root}` or
  `{:error, :no_root}`. `BL_DAEMON_ROOT` overrides everything.
  """
  def resolve_root(cwd) when is_binary(cwd) do
    case System.get_env("BL_DAEMON_ROOT") do
      dir when is_binary(dir) and dir != "" ->
        {:ok, real_path(dir)}

      _ ->
        find_root(Path.expand(cwd))
    end
  end

  # --- internals ---

  defp find_root(dir) do
    cond do
      tree_root?(dir) -> {:ok, real_path(dir)}
      dir == "/" or dir == "." -> {:error, :no_root}
      true -> find_root(Path.dirname(dir))
    end
  end

  defp tree_root?(dir) do
    File.exists?(Path.join([dir, "priv", "boot", "core.bl"])) or
      (File.exists?(Path.join([dir, "bin", "bl"])) and File.dir?(Path.join(dir, "releases")))
  end

  # realpath via File.stat chasing symlinks; falls back to Path.expand when the
  # path does not exist (the caller has already ensured existence where it
  # matters).
  defp real_path(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, target} ->
        resolved = List.to_string(target)
        abs = if Path.type(resolved) == :absolute, do: resolved, else: Path.join(Path.dirname(path), resolved)
        real_path(Path.expand(abs))

      _ ->
        Path.expand(path)
    end
  end

  # Create `dir` (and parents) 0700 if absent; if present, assert it is a real
  # directory this user owns with no group/other access. Never follow a symlink
  # into someone else's tree.
  defp ensure_secure_dir(dir) do
    case :file.read_link_info(String.to_charlist(dir)) do
      {:ok, info} ->
        verify_dir_info(dir, info)

      {:error, :enoent} ->
        case File.mkdir_p(dir) do
          :ok ->
            _ = File.chmod(dir, 0o700)
            :ok

          {:error, reason} ->
            {:error, {:mkdir_failed, dir, reason}}
        end

      {:error, reason} ->
        {:error, {:stat_failed, dir, reason}}
    end
  end

  # file_info tuple: {:file_info, size, type, access, atime, mtime, ctime,
  #   mode, links, major, minor, inode, uid, gid}
  defp verify_dir_info(dir, info) do
    type = elem(info, 2)
    mode = elem(info, 7)
    uid = elem(info, 12)

    cond do
      type != :directory ->
        {:error, {:not_a_directory, dir}}

      uid != current_uid() ->
        {:error, {:wrong_owner, dir, uid}}

      (mode &&& 0o077) != 0 ->
        # tighten a loose dir we own rather than refuse — a prior umask slip
        _ = File.chmod(dir, 0o700)
        :ok

      true ->
        :ok
    end
  end

  # The process's real uid. Elixir exposes no getuid, so probe once: create a
  # file, read back its owner (the creating uid), memoise in :persistent_term.
  # `BL_TEST_UID` overrides for tests that simulate a foreign-owned dir.
  defp current_uid do
    case System.get_env("BL_TEST_UID") do
      v when is_binary(v) and v != "" -> String.to_integer(v)
      _ -> cached_uid()
    end
  end

  defp cached_uid do
    case :persistent_term.get({__MODULE__, :uid}, nil) do
      nil ->
        uid = probe_uid()
        :persistent_term.put({__MODULE__, :uid}, uid)
        uid

      uid ->
        uid
    end
  end

  defp probe_uid do
    path = Path.join(System.tmp_dir!(), "bl-uid-probe-#{:erlang.unique_integer([:positive])}")
    File.write!(path, "")

    uid =
      case :file.read_file_info(String.to_charlist(path)) do
        {:ok, info} -> elem(info, 12)
        _ -> 0
      end

    _ = File.rm(path)
    uid
  end
end
