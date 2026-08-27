defmodule BeamLisp.Spell.Build do
  @moduledoc """
  The filesystem protocol with a running `spacetime serve`.

  beam-lisp owns the machine; verse owns the view compile. The seam between
  them is two files in the served site directory:

    * `index.edn`        — written here on publish, in place (see
      `write_and_await/3`: a rename swaps the inode and serve's watcher
      never sees the change)
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

  @doc """
  The URL the page's bundle script loads from.

  Root-relative by default: the bundle is a build artifact in `priv/static`
  (see the host app's page task), served by `Plug.Static` from the SAME origin
  as the app. One origin means no CORS, no second port in any instruction, and
  no way to point a browser at the bundle server by mistake — where the page's
  assigns resolve to nothing and every derived signal throws on undefined.

  Under `live?/0` the URLs point at a running `spacetime serve` instead, which
  recompiles on change. That is a developer's inner loop, opt-in.
  """
  def bundle_url do
    if live?(),
      do: "#{origin()}/__spacetime/runtime.js?entry=#{entry()}",
      else: "/spacetime/spacetime.js"
  end

  @doc "The URL of the page's stylesheet. See `bundle_url/0`."
  def stylesheet_url do
    if live?(),
      do: "#{origin()}/__spacetime/styles.css?entry=#{entry()}",
      else: "/spacetime/spacetime.css"
  end

  @doc """
  Whether the page is served by a live `spacetime serve` rather than from
  `priv/static`.

  One switch, read in every place the choice matters, so the boot's publish and
  the page's URLs can never disagree about which mode this is.
  """
  def live?, do: System.get_env("REEL_LIVE") in ["1", "true"]

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
    status_path = Path.join(site_dir(), "build-status.json")

    # Retire the previous verdict ONLY when the bytes actually change.
    #
    # The original rule was to always delete: the page is deterministic, so a
    # restart with no serve running could otherwise find the LAST session's
    # status carrying this very hash and report `:ok` for a compile that
    # never happened. Sound, but it assumed a rewrite always produces a new
    # verdict — and it does not. Serve recompiles on a CHANGE event, and
    # writing identical bytes is not a change: no event, no compile, no
    # status. Having just deleted the only verdict, this function then waited
    # out its full deadline and blamed a serve that was running perfectly.
    #
    # It presented as a flake — the first check after any real edit passed,
    # every repeat run failed — which is exactly what an unpublished race
    # looks like from the outside.
    #
    # Identical bytes + a verdict already carrying this hash means a serve
    # has compiled precisely these bytes into precisely this site dir. That
    # is the thing the delete was protecting, so keep the verdict and let the
    # await below match it immediately.
    # The verdict must name THIS content, not merely exist: a status left by
    # a different page is exactly the stale verdict the delete guards against.
    hash = sha256_hex(content)

    unchanged? =
      match?({:ok, %{"content_sha256" => ^hash}}, status()) and
        File.read(target) == {:ok, content}

    unless unchanged?, do: File.rm(status_path)

    # IN PLACE, not through a rename. An atomic rename replaces the file's
    # INODE, and serve's watcher is registered against the inode it saw at
    # boot — so the new entry is invisible to it, no compile runs, no status
    # is written, and this function waits out its full deadline before
    # blaming a serve that is running perfectly well.
    #
    # Measured against a live `spacetime serve`: three renames produced no
    # rebuild in 61s each; an in-place write produced one every time. The
    # rename was there for atomicity, but the reader is a watcher rather
    # than a concurrent parser, and a torn read simply triggers a second
    # compile when the write completes. Losing the rebuild entirely is the
    # worse failure — and it presented as a flake, passing whenever some
    # earlier write happened to leave a matching verdict behind.
    File.write!(target, content)

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
