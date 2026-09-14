defmodule BeamLisp.Daemon.Ports do
  @moduledoc """
  Named ports for a tree's warm session.

  A project declares the ports it serves on in `env.bl`:

      :ports {:web 4000 :metrics {:port 0} :ui 7700}

  `{:port 0}` means ephemeral: the OS chooses, the registry records what it
  chose, and nobody has to care. A number means the project wants THAT port, and
  if it is taken the session says so rather than quietly serving somewhere else.

  ## Truth is a file, not a table

  Each claim is one file under the runtime dir, a term holding the name, the
  port, whether the port was chosen, the owning tree, the OS pid and the time.
  The obvious alternative (a GenServer per daemon, mirroring `WatchRegistry`)
  cannot answer the question that matters: the collision this exists to catch is
  BETWEEN daemons, and one VM's table cannot see another's. Files can, and they
  survive a crash, which is exactly when a stale claim needs cleaning.

  A claim whose process is gone is stale and is swept on sight; a claim whose
  port is held by some process nobody claimed is reported as such, never
  silently taken over.

  ## The key says what kind of claim it is

  A PINNED port is a promise about a NUMBER — `:ports {:web 4000}` means this
  project serves on 4000 — and only one tree on the machine can keep that
  promise, so the name alone is the key and a second tree is refused by name.

  An EPHEMERAL port is nobody's promise: the OS chose the number, so the claim
  is a SESSION's own address and is keyed by name AND tree. Keying it by name
  alone made a second tree's dashboard fail to start because an unrelated tree
  happened to be running one — a collision the user could neither see nor fix,
  and never a real one: two ephemeral claims take different numbers by
  construction.

  ## A claim carries its NAMES

  A claim also holds the hosts the port answers to
  (`BeamLisp.Daemon.Names`). They ride in the claim — one file, owned by the
  process that actually holds the port — so a router can route by name without
  reading any project file: the registry is the routing table, which is what
  lets `BeamLisp.Daemon.Gateway` stay ignorant of `env.bl`.
  """

  alias BeamLisp.Daemon.Paths

  @doc """
  Claim `name` for this session, preferring `want`. `0` asks the OS for a free
  port. Returns `{:ok, port}` or `{:error, reason}` where reason is
  `{:taken, claim}` (another session holds the name) or `{:port_busy, port,
  claim}` (the wanted number is in use).

  `:hosts` are the names this port answers to. They are recorded when the claim
  is made; re-claiming a name this same process already holds keeps the port it
  has, and is idempotent.
  """
  def claim(name, want, opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    pid = normalize_pid(Keyword.get(opts, :pid))
    hosts = normalize_hosts(Keyword.get(opts, :hosts))

    with {:ok, dir} <- ports_dir() do
      case held_here(dir, name, want, root, pid) do
        # this session already holds the NAME. Asking for 0 means "any port",
        # and it already has one — re-probing would move a live listener.
        {:ok, existing} when want == 0 -> {:ok, existing}
        {:ok, ^want} -> {:ok, want}
        # this session holds the name, but wants a different number: move it
        {:ok, _other} -> take(dir, name, want, root, pid, hosts)
        {:held, claim} -> {:error, {:taken, claim}}
        :free -> take(dir, name, want, root, pid, hosts)
      end
    end
  end

  # Hosts are strings, lowercased and deduped: a `Host:` header is compared to
  # them verbatim, and no caller should have to guess the case a name was
  # claimed in. Anything else in the list is not a host and is dropped.
  defp normalize_hosts(nil), do: []

  defp normalize_hosts(hosts) when is_list(hosts) do
    hosts
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp normalize_hosts(_other), do: []

  # `:os.getpid/0` answers a CHARLIST, and a pid kept in that shape compares
  # unequal to the integer a caller passes — which is how every claim came to
  # look stale and be swept the moment it was written. One shape, integers.
  defp normalize_pid(nil), do: :os.getpid() |> List.to_integer()
  defp normalize_pid(pid) when is_integer(pid), do: pid
  defp normalize_pid(pid) when is_list(pid), do: List.to_integer(pid)
  defp normalize_pid(other), do: other

  defp held_here(dir, name, want, root, pid) do
    case read_claim(Path.join(dir, file_name(name, want, root))) do
      {:ok, %{pid: ^pid} = claim} -> {:ok, claim.port}
      {:ok, claim} -> if alive?(claim), do: {:held, claim}, else: :free
      _ -> :free
    end
  end

  defp take(dir, name, want, root, pid, hosts) do
    case bindable(want) do
      {:ok, port} ->
        claim = %{
          name: to_string(name),
          port: port,
          pinned: want != 0,
          hosts: hosts,
          tree_id: Paths.tree_id(root),
          root: root,
          pid: pid,
          claimed_at: System.system_time(:second)
        }

        with :ok <- write_claim(dir, file_name(name, want, root), claim), do: {:ok, port}

      {:error, :eaddrinuse} ->
        {:error, {:port_busy, want, holder(want)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Give up `name` for this session. Idempotent: releasing a name nobody holds
  is `:ok`.

  Only claims THIS tree made are dropped — the session's own ephemeral key and
  the pinned key when this session holds it. Another tree can hold the pinned
  key, and one session ending must never erase another session's address.
  """
  def release(name, opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())

    with {:ok, dir} <- ports_dir() do
      for key <- [file_name(name, 0, root), file_name(name, 1, root)] do
        case read_claim(Path.join(dir, key)) do
          {:ok, %{root: ^root}} -> File.rm(Path.join(dir, key))
          _ -> :ok
        end
      end
    end

    :ok
  end

  @doc "Every live claim, oldest name first, as maps `%{name, port, pinned, hosts,
  tree_id, root, pid, claimed_at}`. Stale claims (owner gone) are swept as they
  are met, so a crashed daemon leaves nothing behind for the next one to trip
  over."
  def list do
    case ports_dir() do
      {:ok, dir} ->
        dir
        |> File.ls!()
        |> Enum.sort()
        |> Enum.flat_map(&read_live(Path.join(dir, &1)))

      _ ->
        []
    end
  end

  @doc """
  The port `name` is held on for `:root`'s session, or nil.

  The session's OWN claim wins. An ephemeral name belongs to the tree that
  claimed it — nobody chose that number — so a second tree asking must learn ITS
  port, never the neighbour's. Only when the session holds nothing does the
  machine-wide PINNED claim answer, which is what makes a name somebody chose
  shared truth rather than a coincidence.
  """
  def port_of(name, opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())

    case ports_dir() do
      {:ok, dir} ->
        Enum.find_value([file_name(name, 0, root), file_name(name, 1, root)], fn key ->
          case read_claim(Path.join(dir, key)) do
            {:ok, claim} -> if alive?(claim), do: claim.port, else: nil
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  end

  @doc "The live claim holding `port`, or nil."
  def holder(port) do
    Enum.find(list(), fn c -> c.port == port end)
  end

  @doc """
  The live claim answering to `host`, or nil. The match is on the claim's own
  host list, lowercased — `Host:` headers arrive in whatever case the client
  wrote, and DNS is case-insensitive.
  """
  def holder_of_host(host) when is_binary(host) do
    wanted = host |> String.downcase() |> String.trim()

    Enum.find(list(), fn c -> wanted in Map.get(c, :hosts, []) end)
  end

  # --- internals ---

  defp ports_dir do
    with {:ok, base} <- Paths.runtime_dir() do
      dir = Path.join(base, "ports")


      case File.mkdir_p(dir) do
        :ok ->
          _ = File.chmod(dir, 0o700)
          {:ok, dir}

        {:error, reason} ->
          {:error, {:ports_dir, reason}}
      end
    end
  end

  defp file_name(name, want, root) do
    name = name |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
    if want == 0, do: "#{name}@#{Paths.tree_id(root)}", else: name
  end

  # Bind the wanted port and let it go again. For `0` this is how an ephemeral
  # port is chosen; for a number it is the proof the port is free RIGHT NOW. The
  # gap between this probe and the server's own bind is milliseconds and is why
  # a caller retries with `0` when the bind fails (see Server.claim_ui/1).
  defp bindable(0), do: probe(0)

  defp bindable(port) when is_integer(port) and port > 0 do
    case probe(port) do
      {:ok, ^port} -> {:ok, port}
      other -> other
    end
  end

  defp bindable(other), do: {:error, {:bad_port, other}}

  # A listen on ANY address, not loopback: "is this port free" must hold on
  # every interface the server might take, and binding all of them is the
  # strictest way to ask. `reuseaddr: false` for the same reason — a probe that
  # succeeds on a socket another process is also listening on would be no probe.
  defp probe(port) do
    opts = [:binary, {:packet, 4}, {:active, false}, {:reuseaddr, false}, {:ip, {0, 0, 0, 0}}]

    case :gen_tcp.listen(port, opts) do
      {:ok, lsock} ->
        actual =
          case :inet.sockname(lsock) do
            {:ok, {_ip, p}} -> p
            _ -> port
          end

        :gen_tcp.close(lsock)
        {:ok, actual}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_claim(dir, key, claim) do
    path = Path.join(dir, key)
    tmp = path <> ".tmp.#{:erlang.unique_integer([:positive])}"

    with :ok <- File.write(tmp, :erlang.term_to_binary(claim)) do
      _ = File.chmod(tmp, 0o600)

      case File.rename(tmp, path) do
        :ok ->
          :ok

        {:error, reason} ->
          File.rm(tmp)
          {:error, {:write_claim, reason}}
      end
    end
  end

  defp read_live(path) do
    case read_claim(path) do
      {:ok, claim} ->
        if alive?(claim) do
          [claim]
        else
          File.rm(path)
          []
        end

      _ ->
        []
    end
  end

  # The shape a claim must have, matched rather than asserted: a file that
  # carries anything else (an older format, a truncated write, a struct) is
  # `:error`, which the caller treats as "not a claim" and sweeps. A claim
  # written before hosts existed simply has none.
  defp read_claim(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, %{name: _, port: _, pid: _} = claim} <- safe_binary_to_term(bin) do
      {:ok, Map.put(claim, :hosts, Map.get(claim, :hosts) || [])}
    else
      _ -> :error
    end
  end

  defp safe_binary_to_term(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    _ -> :error
  end

  # A claim's owner: the same question `alive_pid?/1` answers for the gateway's
  # own endpoint file, asked once. A claim always carries a pid, so there is one
  # clause and no fallback to keep in step with it.
  defp alive?(claim), do: alive_pid?(Map.get(claim, :pid))

  @doc """
  Whether the OS process `pid` is alive. Every endpoint that outlives the VM
  that wrote it needs this answer — a port claim, the gateway's own endpoint —
  because "the file is there" stops being true the moment its owner dies, and a
  stale endpoint is never authority.

  Our own pid is checked in-VM. A foreign one goes through `/proc` (the runtime
  dir, the socket, the daemon: this story is Unix-shaped already). Where `/proc`
  is absent a claim is RESPECTED rather than swept — refusing a port is
  recoverable, stealing one is not.
  """
  def alive_pid?(pid) when is_integer(pid) do
    if pid == List.to_integer(:os.getpid()) do
      true
    else
      case File.dir?("/proc") do
        true -> File.dir?("/proc/#{pid}")
        false -> true
      end
    end
  end

  def alive_pid?(_other), do: false
end
