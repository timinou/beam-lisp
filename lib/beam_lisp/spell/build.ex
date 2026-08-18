defmodule BeamLisp.Spell.Build do
  @moduledoc """
  The filesystem protocol with a running `spacetime serve`.

  beam-lisp owns the machine; verse owns the view compile. The seam between
  them is two files in the served site directory:

    * `index.edn`        — written here on publish (tmp + rename)
    * `build-status.json` — written by serve after every compile, carrying
      `content_sha256` of the source it compiled

  The handshake: hash what you wrote, poll until the status carries the same
  hash, then read `ok`/`diagnostics`. The hash (not the mtime) is the proof,
  because mtime truncation can alias two rapid writes.

  Nothing here shells out. The compile happens inside the long-running serve
  process (warm registry, no per-publish binary spawn); this module only
  writes and reads files.
  """

  @doc "The directory `spacetime serve` serves and watches (project-local)."
  def site_dir, do: Application.get_env(:beam_lisp, :spell_site_dir, "spell/ui")

  @doc "The page entry the serve process compiles and the browser loads."
  def entry, do: "index.edn"

  @doc "HTTP origin of the verse dev server."
  def origin do
    port = Application.get_env(:beam_lisp, :spell_verse_port, 4444)
    "http://127.0.0.1:#{port}"
  end

  @doc "WebSocket origin of the verse dev server (live reload)."
  def ws_origin, do: String.replace_prefix(origin(), "http", "ws")

  @doc "The URL the page's bundle script loads from."
  def bundle_url, do: "#{origin()}/__spacetime/runtime.js?entry=#{entry()}"

  @doc "The URL of the page's stylesheet."
  def stylesheet_url, do: "#{origin()}/__spacetime/styles.css?entry=#{entry()}"

  @doc """
  Write `content` as `<site>/<entry>` and await serve's verdict for exactly
  that content.

  `{:ok, status}` | `{:error, reason}`. A compile failure is
  `{:error, diagnostics}` — the page was refused by verse, with the reasons.
  A missing serve is `{:error, "…"}` after `timeout_ms` of no matching status.
  """
  def write_and_await(entry, content, timeout_ms \\ 30_000) do
    File.mkdir_p!(site_dir())
    target = Path.join(site_dir(), entry)
    tmp = target <> ".tmp"
    status_path = Path.join(site_dir(), "build-status.json")

    # Retire the previous verdict BEFORE writing: the page is deterministic,
    # so a restart with no serve running would otherwise find the LAST
    # session's status carrying this very hash and report :ok for a compile
    # that never happened. With the old status gone, a matching status can
    # only be written by a serve that compiled THESE bytes. (Single-writer
    # protocol: a second publisher sharing the site would see its own await
    # disturbed by this delete — the same reason the tests stay async:false.)
    File.rm(status_path)

    File.write!(tmp, content)
    File.rename!(tmp, target)

    hash = sha256_hex(content)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await(hash, deadline)
  end

  defp await(hash, deadline) do
    case status() do
      {:ok, %{"content_sha256" => ^hash} = status} ->
        if status["ok"] do
          {:ok, status}
        else
          {:error, format_diagnostics(status["diagnostics"])}
        end

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error,
           "no compile verdict for the page within the deadline — " <>
             "is `spacetime serve #{site_dir()}` running? " <>
             "(the app starts it when the binary is present)"}
        else
          Process.sleep(100)
          await(hash, deadline)
        end
    end
  end

  @doc "The current build status, decoded; `{:error, _}` when absent or mid-write."
  def status do
    with {:ok, text} <- File.read(Path.join(site_dir(), "build-status.json")),
         {:ok, decoded} <- decode(text) do
      {:ok, decoded}
    end
  end

  @doc "Fetch a compiled asset (`runtime.js`, `styles.css`) for `entry` from serve."
  def get_asset(asset, entry \\ entry()) do
    url = "#{origin()}/__spacetime/#{asset}?entry=#{URI.encode(entry)}"

    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 30_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_, code, _}, _headers, body}} -> {:error, "GET #{url} → #{code}: #{body}"}
      {:error, reason} -> {:error, "GET #{url} failed: #{inspect(reason)}"}
    end
  end

  defp sha256_hex(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp decode(text) do
    {:ok, JSON.decode!(text)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp format_diagnostics(diagnostics) when is_list(diagnostics) do
    diagnostics
    |> Enum.map(fn d ->
      loc =
        case {d["line"], d["column"]} do
          {nil, _} -> ""
          {line, col} -> " (#{d["file_path"] || entry()}:#{line}:#{col || 0})"
        end

      "#{d["severity"] || "error"}#{loc}: #{d["message"]}"
    end)
    |> Enum.join("\n")
  end

  defp format_diagnostics(other), do: inspect(other)
end
