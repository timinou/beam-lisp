defmodule BeamLisp.Daemon.CA do
  @moduledoc """
  The certificate authority behind `https://<name>/`.

  A browser accepts an `https://` name only if it can verify the certificate,
  and no public CA will vouch for `web.pulse.test`. So `bl` mints its own chain,
  in the VM, with `:public_key` through `x509` — no openssl, no mkcert, nothing
  to configure:

  * one **root**, generated on first use and kept under the runtime dir
    (`root.pem` public, `root.key` 0600);
  * a **leaf per NAME**, with that name in the SAN, signed by the root.

  Minted per name, not wildcarded, because the name is what the client asked
  for: the gateway takes it from the TLS handshake (SNI) and answers for exactly
  that name. A leaf costs one RSA keypair, is written beside the root, and is
  reused from memory for the life of the install.

  The root is the part a developer has to trust. `root_pem/0` is what the
  gateway serves at `/bl-ca.crt` and what `bl install proxy` prints the import
  for. The root's private key never leaves this process: callers get leaves and
  the public root, never the signing key.
  """

  use GenServer

  alias BeamLisp.Daemon.Paths

  @name __MODULE__
  # 825 days is what Apple allows for a leaf issued by a user-installed root,
  # so staying under it keeps every browser quiet without anyone thinking about
  # certificate renewal on a dev box.
  @leaf_days 825
  @root_days 3_650

  # --- public ---

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @doc "Start the authority if it is not running. Idempotent."
  def ensure_started do
    case Process.whereis(@name) do
      nil -> start_link()
      pid -> {:ok, pid}
    end
  end

  @doc "The root certificate, PEM — what a client has to trust."
  def root_pem, do: GenServer.call(@name, :root_pem, 30_000)

  @doc """
  `:ssl` options for serving `name`: the leaf certificate and its key, DER.

  Generated on first ask and cached, so the first handshake for a name costs a
  keypair and every later one costs a map lookup.
  """
  def ssl_opts(name) when is_binary(name), do: GenServer.call(@name, {:ssl_opts, name}, 30_000)

  @doc "Path of the root certificate on disk (PEM)."
  def root_path, do: GenServer.call(@name, :root_path, 30_000)

  # --- state ---

  @impl true
  def init(_opts) do
    with {:ok, dir} <- dir(), :ok <- File.mkdir_p(dir) do
      {root_cert, root_key} = load_or_mint_root(dir)

      {:ok,
       %{
         dir: dir,
         root_cert: root_cert,
         root_key: root_key,
         # name => ssl opts: the hot path for every handshake
         leaves: %{}
       }}
    else
      {:error, reason} -> {:stop, {:ca_dir, reason}}
    end
  end

  @impl true
  def handle_call(:root_pem, _from, state) do
    {:reply, X509.Certificate.to_pem(state.root_cert), state}
  end

  def handle_call(:root_path, _from, state) do
    {:reply, Path.join(state.dir, "root.pem"), state}
  end

  def handle_call({:ssl_opts, name}, _from, state) do
    case Map.fetch(state.leaves, name) do
      {:ok, opts} ->
        {:reply, {:ok, opts}, state}

      :error ->
        case leaf_for(state, name) do
          {:ok, opts} -> {:reply, {:ok, opts}, Map.put(state, :leaves, Map.put(state.leaves, name, opts))}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  # --- the root ---

  defp load_or_mint_root(dir) do
    cert_path = Path.join(dir, "root.pem")
    key_path = Path.join(dir, "root.key")

    case {read_pem(cert_path), read_pem(key_path)} do
      {{:ok, cert}, {:ok, key}} ->
        {cert, key}

      _ ->
        key = X509.PrivateKey.new_rsa(2048)

        cert =
          X509.Certificate.self_signed(
            key,
            root_subject(),
            template: :root_ca,
            validity: @root_days
          )

        write_private(key_path, X509.PrivateKey.to_pem(key))
        File.write!(cert_path, X509.Certificate.to_pem(cert))
        {cert, key}
    end
  end

  # The root names the machine it belongs to: several checkouts, several users,
  # several roots, and a trust store that can tell them apart.
  defp root_subject do
    who = System.get_env("USER") || "user"
    host = (System.get_env("HOSTNAME") || "localhost") |> String.split(".") |> hd()
    "/CN=beam-lisp local CA/O=beam-lisp/OU=#{who}@#{host}"
  end

  # --- leaves ---

  defp leaf_for(state, name) do
    with {:ok, key, cert} <- load_leaf(state, name) do
      {:ok,
       [
         cert: X509.Certificate.to_der(cert),
         key: {:RSAPrivateKey, X509.PrivateKey.to_der(key)},
         # Nothing here needs a client certificate, and asking for one turns a
         # browser misconfiguration into a handshake failure with no sentence.
         verify: :verify_none,
         # http/1.1 only, on purpose: the gateway splices bytes and forwards a
         # head it did not parse, so offering h2 would promise a protocol it
         # cannot speak. ALPN is how that promise is not made.
         alpn_preferred_protocols: ["http/1.1"],
         versions: [:"tlsv1.2", :"tlsv1.3"],
         reuse_sessions: true
       ]}
    end
  end

  defp load_leaf(state, name) do
    key_path = Path.join(state.dir, "#{safe(name)}.key")
    cert_path = Path.join(state.dir, "#{safe(name)}.cert")

    case {read_pem(cert_path), read_pem(key_path)} do
      {{:ok, cert}, {:ok, key}} ->
        {:ok, key, cert}

      _ ->
        key = X509.PrivateKey.new_rsa(2048)

        cert =
          X509.Certificate.new(
            X509.PublicKey.derive(key),
            "/CN=#{name}",
            state.root_cert,
            state.root_key,
            template: :server,
            validity: @leaf_days,
            extensions: [subject_alt_name: san(name)]
          )

        write_private(key_path, X509.PrivateKey.to_pem(key))
        File.write!(cert_path, X509.Certificate.to_pem(cert))
        {:ok, key, cert}
    end
  end

  # A name, and `localhost` beside it when the name lives under `.localhost`, so
  # one leaf answers both spellings. The extension has to be BUILT
  # (`X509.Certificate.Extension`), not spelled as a keyword list: the encoder
  # wants the ASN.1 record, and a bare `[dNSName: …]` is rejected deep inside
  # `:pubkey_cert_records` with a clause error that names nothing useful.
  # Names arrive already normalized (lowercase, no port) from the gateway.
  defp san(name) do
    names =
      if name == "localhost" or String.ends_with?(name, ".localhost") do
        [name, "localhost"]
      else
        [name]
      end

    X509.Certificate.Extension.subject_alt_name(Enum.uniq(names))
  end

  # A file name, not a path: the name arrives from a TLS handshake, so it is
  # attacker-controlled in principle and never trusted as a path.
  defp safe(name) do
    name
    |> String.replace(~r/[^A-Za-z0-9._-]/u, "_")
    |> String.slice(0, 120)
  end

  defp write_private(path, pem) do
    File.write!(path, pem)
    File.chmod!(path, 0o600)
  end

  defp read_pem(path) do
    with {:ok, pem} <- File.read(path),
         [entry | _] <- :public_key.pem_decode(pem) do
      {:ok, decode(entry)}
    else
      _ -> :error
    end
  end

  defp decode({:Certificate, der, _}), do: X509.Certificate.from_der!(der)
  defp decode({:RSAPrivateKey, der, _}), do: X509.PrivateKey.from_der!(der)
  defp decode(other), do: raise("unexpected PEM entry: #{inspect(other)}")

  defp dir do
    with {:ok, base} <- Paths.runtime_dir(), do: {:ok, Path.join(base, "ca")}
  end
end
