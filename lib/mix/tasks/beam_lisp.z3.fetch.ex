defmodule Mix.Tasks.BeamLisp.Z3.Fetch do
  @moduledoc """
  Fetch the pinned, bundled z3 solver into `priv/z3/`.

  MVP-C's decision: z3 is a NATIVE CALL (port driver), and the solver is
  resolved at exactly one place — `priv/z3/bin/z3` — never the PATH.
  This task downloads the official z3 release zip for the current
  platform, verifies it against the pinned sha256, extracts `bin/`,
  `lib/` and `include/` into `priv/z3/`, and smoke-runs `--version`.

  The fetched tree is gitignored: it is a derived artifact, reproducible
  by re-running this task. Re-pinning z3 means bumping `@version` and
  the digests in `@assets` (GitHub's release API prints them as
  `digest: sha256:…` per asset).
  """

  @shortdoc "Fetch the pinned z3 binary into priv/z3/"

  use Mix.Task

  @version "4.16.0"
  @base "https://github.com/Z3Prover/z3/releases/download/z3-#{@version}"

  # {os, arch} => {asset basename, sha256 of the zip}
  @assets %{
    {:linux, :x64} =>
      {"z3-4.16.0-x64-glibc-2.39.zip",
       "7288c49a5bd6dbafd7b0b0d1f65956b91672da24b08f09242919af159be3418e"},
    {:linux, :arm64} =>
      {"z3-4.16.0-arm64-glibc-2.38.zip",
       "87fcd963d3eecb0f12cf1c3ef0ad74e84a3a7bd3caed5d94445645ef94ae6274"},
    {:macos, :x64} =>
      {"z3-4.16.0-x64-osx-15.7.3.zip",
       "d95519c4f3ed9393bb5f996e514c8f177bb148989bdfc32e95587f0307c4e7b0"},
    {:macos, :arm64} =>
      {"z3-4.16.0-arm64-osx-15.7.3.zip",
       "41828fa07d5cb77bfaee326e8e6dac074f26329c09c633f9e66012bb917cf8ae"},
    {:windows, :x64} =>
      {"z3-4.16.0-x64-win.zip",
       "de4d813e47202394a093547dbdb5699ee076529aa853463e007539775cd7e836"},
    {:windows, :arm64} =>
      {"z3-4.16.0-arm64-win.zip",
       "f98dd099a69ae9784a13eec76eeced12aa733f4f30389b5ddc724c4c21747e94"}
  }

  @impl true
  def run(_argv) do
    {asset, sha256} = asset_for(platform())
    url = "#{@base}/#{asset}"
    dest = Path.join([:code.priv_dir(:beam_lisp) |> to_string(), "z3"])

    Mix.shell().info("fetching #{url}")
    body = download(url)

    actual = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    if actual != sha256 do
      Mix.raise("sha256 mismatch for #{asset}\n  pinned:  #{sha256}\n  actual:  #{actual}")
    end

    Mix.shell().info("sha256 verified; extracting to #{dest}")
    File.rm_rf!(dest)
    File.mkdir_p!(dest)
    extract(body, dest)
    prune(dest)

    exe = Path.join([dest, "bin", exe_name()])
    File.chmod!(exe, 0o755)

    {version, 0} = System.cmd(exe, ["--version"])
    Mix.shell().info("bundled z3 ready: #{String.trim(version)}")
  end

  defp platform do
    sys = :erlang.system_info(:system_architecture) |> to_string()

    arch =
      cond do
        String.starts_with?(sys, "x86_64") or String.starts_with?(sys, "amd64") -> :x64
        String.starts_with?(sys, "aarch64") or String.starts_with?(sys, "arm64") -> :arm64
        true -> Mix.raise("unsupported CPU architecture: #{sys}")
      end

    os =
      case :os.type() do
        {:unix, :darwin} -> :macos
        {:unix, :linux} -> :linux
        {:win32, _} -> :windows
        other -> Mix.raise("unsupported OS: #{inspect(other)}")
      end

    {os, arch}
  end

  defp asset_for(key) do
    @assets[key] || Mix.raise("no pinned z3 asset for #{inspect(key)} (z3 #{@version})")
  end

  defp download(url) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    case :httpc.request(:get, {String.to_charlist(url), []}, [ssl: ssl],
           body_format: :binary
         ) do
      {:ok, {{_, code, _}, _headers, body}} when code in 200..299 and is_binary(body) ->
        body

      {:ok, {{_, code, _}, _headers, _body}} ->
        Mix.raise("download failed: HTTP #{code} from #{url}")

      {:error, reason} ->
        Mix.raise("download failed: #{inspect(reason)} from #{url}")
    end
  end

  # The zip wraps everything in a top-level `z3-<ver>-<platform>/`
  # directory; extract that directory's CONTENTS into priv/z3/.
  defp extract(zip_binary, dest) do
    {:ok, files} = :zip.extract(zip_binary, cwd: String.to_charlist(dest))

    extracted_root =
      files
      |> Enum.map(&to_string/1)
      |> Enum.map(&Path.relative_to(&1, dest))
      |> Enum.map(&(String.split(&1, "/") |> hd()))
      |> Enum.uniq()

    case extracted_root do
      [root] ->
        for entry <- File.ls!(Path.join(dest, root)) do
          File.rename!(Path.join([dest, root, entry]), Path.join(dest, entry))
        end

        File.rm_rf!(Path.join(dest, root))

      other ->
        Mix.raise("unexpected zip layout, roots: #{inspect(other)}")
    end
  end

  # The release zip ships bindings we never touch (python, java, .NET,
  # static lib, headers) — ~110MB of dead weight per machine. Keep the
  # solver, its shared lib, and the license.
  @keep ["z3", "z3.exe", "libz3.so", "libz3.dylib", "libz3.dll", "LICENSE.txt"]

  defp prune(dest) do
    dest
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(fn p ->
      File.dir?(p) or Path.basename(p) in @keep
    end)
    |> Enum.each(&File.rm_rf!/1)

    # drop dirs the file pass emptied (deepest first), keeping the root
    dest
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.each(fn d -> if File.ls!(d) == [], do: File.rmdir!(d) end)
  end

  defp exe_name do
    case :os.type() do
      {:win32, _} -> "z3.exe"
      _ -> "z3"
    end
  end
end
