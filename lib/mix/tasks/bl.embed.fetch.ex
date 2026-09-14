defmodule Mix.Tasks.Bl.Embed.Fetch do
  @moduledoc """
  Fetch the pinned static code-embedding model into the user cache.

      mix bl.embed.fetch [--dir PATH] [--bundle] [--force]

  ## What is fetched, and why this model

  `minishlab/potion-code-16M-v2` — a Model2Vec *static* embedding model:
  16M parameters, 256 dimensions, ~33 MB on disk, distilled from
  `nomic-ai/CodeRankEmbed` on the CornStack code corpus. It is a lookup table
  plus a mean, not a transformer, so an embed is a hash lookup rather than a
  forward pass. The whole point is that it is the smallest thing that still
  retrieves code by meaning: a code transformer of comparable quality
  (`jina-embeddings-v2-base-code`, 161M params) costs ~20x the resident memory
  and ~1000x the latency for a corpus this size.

  Three files, all three pinned by sha256 below. The digest is the contract: an
  upstream re-upload that changes one weight byte must fail LOUDLY here rather
  than quietly change what every already-cached embedding in every index means.
  A vector space is identified by its weights; silently swapping them makes
  every stored vector a lie.

  ## Where it goes

  Two roots, and which one you want depends on who will READ the weights:

  * default — `BeamLisp.Model.ambient_dir/1`: `$BEAM_LISP_MODEL_DIR`, else
    `$XDG_CACHE_HOME/beam_lisp/models`. Shared across checkouts and worktrees,
    for the reason given in that module: one 33 MB copy per machine, not per
    tree. This is what a person working on beam-lisp wants.
  * `--bundle` — `priv/embed/`, the copy `mix bl.build` packs into the drop.
    That is what makes a shipped `bl` answer with no network, no Mix and no
    cache on the box; `mix bl.build` runs exactly this step before it packs.

  A drop reads the BUNDLED copy; a source tree reads whichever exists (see
  `BeamLisp.Model.dir/1`). `--dir PATH` writes into PATH itself, for a test or
  an unusual install.

  The capability stays OPTIONAL either way: everything that uses it checks
  availability first and reads as absent when the weights are not there (see
  `priv/lib/code/embed.bl`).

  ## Offline

  Only this task touches the network. Nothing at query time does — after one
  fetch, semantic search over code runs with the machine unplugged.
  """

  @shortdoc "Fetch the pinned static code-embedding model"

  use Mix.Task

  @model "minishlab/potion-code-16M-v2"
  @base "https://huggingface.co/#{@model}/resolve/main"

  # The DIRECTORY is the bare model name, because that is what the code that
  # reads the weights computes for itself (`code.embed/MODEL` →
  # `BeamLisp.Model.dir`). The org prefix belongs to the URL and stops there:
  # resolving it into the path put the files under
  # `models/minishlab/potion-code-16M-v2`, which nothing ever looks in — the
  # fetch reported success while semantic search still saw no model on disk.
  @dir_name "potion-code-16M-v2"

  # name => sha256 (pinned; computed from the upstream artifacts at the
  # revision whose weights these are). Sizes are shown in the log so a partial
  # download is visible as one.
  @files %{
    "config.json" => "148e5691a6fcc553437156859701fba017a1ba5d340b170f17e0f3668fb861a7",
    "tokenizer.json" => "107bbdcbad4bff1d299b7a4c3a2fb17c52890688b7dd0e4c9deab79d3c4f3d45",
    "model.safetensors" =>
      "75cf7a6c2171b230ad19b1e7d8e0b1aee86da5a02af8e7cacedd9921d227623c"
  }

  @impl true
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: [dir: :string, bundle: :boolean, force: :boolean])

    dest =
      cond do
        opts[:dir] -> opts[:dir]
        opts[:bundle] -> BeamLisp.Model.bundled_dir(@dir_name)
        true -> BeamLisp.Model.ambient_dir(@dir_name)
      end

    File.mkdir_p!(dest)

    Mix.shell().info("fetching #{@model} into #{dest}")

    for {name, sha} <- Enum.sort(@files) do
      path = Path.join(dest, name)

      # `opts[:force] != true`, NOT `not opts[:force]`: this Elixir's `Kernel.not/1`
      # is strict about booleans and raises ArgumentError on the nil an absent
      # flag produces. The failure lands on this line with no mention of the
      # flag, so the mistake reads as a broken shell or a bad path — the
      # comparison says what it means and cannot.
      cached? = opts[:force] != true and verified?(path, sha)

      if cached? do
        Mix.shell().info([:green, "  ok    ", :reset, name, " (cached)"])
      else
        body = download("#{@base}/#{name}", name)
        actual = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

        if actual != sha do
          Mix.raise("""
          sha256 mismatch for #{name}

            pinned: #{sha}
            actual: #{actual}

          The upstream artifact changed. If that is expected, re-pin by
          updating @files in #{inspect(__MODULE__)} — after re-verifying that
          the new weights are the ones you mean, because every embedding
          already cached against the old ones is now in a different space.
          """)
        end

        File.write!(path, body)
        Mix.shell().info([:green, "  ok    ", :reset, name, " (#{byte_size(body)} bytes)"])
      end
    end

    # The weights' digest, on disk, for the code that has to decide whether a
    # cached vector is still current: `code.embed/model-id` reads this, and a
    # `.blanalysis` store remembers the marker it produces. Verifying 32 MB of
    # weights on every query would be absurd; verifying them ONCE, here, is what
    # pinning them buys.
    File.write!(Path.join(dest, "DIGEST"), @files["model.safetensors"])

    # Provenance, because these weights now SHIP inside the drop: a
    # redistributed artifact carries its origin, its licence and the digests it
    # was pinned by, next to the bytes rather than in a commit message nobody
    # has. MIT (per the upstream model card) requires the notice to travel with
    # the copy.
    File.write!(Path.join(dest, "PROVENANCE"), provenance(dest))

    Mix.shell().info("static code model ready: #{dest}")

    if opts[:bundle] do
      Mix.shell().info("bundled — `mix bl.build` now ships it (opt out with --no-embed)")
    else
      Mix.shell().info("try it:  bl run examples/code-semantic/01-search-by-meaning.bl")
    end
  end

  defp provenance(dest) do
    digests =
      @files
      |> Enum.sort()
      |> Enum.map_join("\n", fn {name, sha} -> "  #{String.pad_trailing(name, 18)} #{sha}" end)

    """
    PROVENANCE — #{@model}

    A static code-embedding model (Model2Vec: a lookup table and a mean, not a
    transformer), redistributed inside a beam-lisp drop.

      upstream:  https://huggingface.co/#{@model}
      fetched:   #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
      by:        mix bl.embed.fetch (--bundle for the copy a drop carries)
      into:      #{dest}
      licence:   MIT (per the upstream model card; the upstream repository
                 ships no separate LICENSE file — see the model card)

    sha256 of the three files this pinned revision is identified by:

    #{digests}

    Those digests are the contract, and the model.safetensors one is the model's
    IDENTITY: every stored embedding records it, so weights that change silently
    would make every cached vector a lie. A copy without a DIGEST file beside it
    is not a model any caller will read (see BeamLisp.Model.fetched?/1).
    """
  end

  defp verified?(path, sha) do
    case File.read(path) do
      {:ok, body} -> :crypto.hash(:sha256, body) |> Base.encode16(case: :lower) == sha
      _ -> false
    end
  end

  # Retried, because the model host resets a small fraction of connections
  # (observed: `Recv failure: Connection reset by peer` on an otherwise healthy
  # route). A single retry-with-backoff is the difference between "fetching the
  # model works" and "fetching the model works if you are lucky", and there is
  # nothing here a retry can corrupt: a partial body never reaches the digest
  # check.
  defp download(url, name, attempts \\ 3)

  defp download(url, name, attempts) do
    case get(url) do
      {:ok, body} ->
        body

      {:error, reason} when attempts > 1 ->
        Mix.shell().info([:yellow, "  retry ", :reset, name, " — #{inspect(reason)}"])
        Process.sleep(1000)
        download(url, name, attempts - 1)

      {:error, reason} ->
        Mix.raise("download failed for #{url}: #{inspect(reason)}")
    end
  end

  defp get(url) do
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

    case :httpc.request(
           :get,
           {String.to_charlist(url), []},
           [ssl: ssl, timeout: 300_000, connect_timeout: 30_000],
           body_format: :binary
         ) do
      {:ok, {{_, code, _}, _headers, body}} when code in 200..299 and is_binary(body) -> {:ok, body}
      {:ok, {{_, code, _}, _, _}} -> {:error, {:http, code}}
      {:error, reason} -> {:error, reason}
    end
  end
end
