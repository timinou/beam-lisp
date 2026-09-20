defmodule BeamLisp.Model do
  @moduledoc """
  Where the static code model's weights live, and WHICH copy to read.

  ## Three roots, and the reason each exists

  A vector space is identified by its weights, so "which copy" is a real
  question with a real answer: `dir/1` returns the first root below that holds a
  COMPLETE fetched copy.

    1. `$BEAM_LISP_MODEL_DIR` — an explicit pin. SET MEANS ANSWER: nothing falls
       through from it, so a test (or a CI job) that points it at an empty
       directory is testing absence, not whatever else the machine holds.
    2. `priv/embed/<name>` — the BUNDLED copy. `mix bl.build` fetches the weights
       in before it packs (`--no-embed` opts out), so a shipped `bl` answers
       semantic queries with no network, no Mix and no cache on the box. The
       drop is the default distribution; the weights ship inside it.
    3. `$XDG_CACHE_HOME/beam_lisp/models/<name>` — the AMBIENT cache
       `bl install embed` fills by default. Shared across checkouts, worktrees
       and branches, which is the arithmetic that keeps 33 MB out of every tree:
       the model is the same bytes for every checkout and is cached rather than
       built. `priv/z3/`'s precedent (fetch per checkout, to match a pinned
       release) buys nothing for it.

  So a source tree works from tier 3 and a drop works from tier 2, and both name
  the same pinned bytes: the sha256 contract lives in the fetch task, and the
  digest file each tier carries is what makes a copy identifiable as those
  bytes.

  ## One rule, two callers

  The `.bl` side (`code.embed`) and the Mix tasks both need this answer, and
  they must agree — weights fetched into one root and read from another is a
  capability that silently reads as absent. So the rule lives here once and both
  call it: Elixir owns the filesystem question, beam-lisp owns what to do about
  the answer.
  """

  @env_dir "BEAM_LISP_MODEL_DIR"

  @doc """
  The AMBIENT root: `$BEAM_LISP_MODEL_DIR`, else
  `$XDG_CACHE_HOME/beam_lisp/models` — the `models` subdirectory of the host
  cache root (`:filename.basedir(:user_cache, …)`, the same OTP answer
  `vm.paths/cache-root` gives beam-lisp), the one answer to "where does this
  machine keep beam-lisp's derived state".

  This is where a fetch writes by DEFAULT. Readers ask `dir/1`, which prefers a
  bundled copy when one is present.

  Resolved PER CALL, never memoised: a test (or a fetch with `--dir`) sets the
  variable and expects the next call to see it. `BeamLisp.AOTCache` learned this
  the same way — a load-time `def` here would fix the directory for every later
  caller in the VM.
  """
  @spec root() :: String.t()
  def root do
    case System.get_env(@env_dir) do
      nil -> Path.join(:filename.basedir(:user_cache, ~c"beam_lisp") |> to_string(), "models")
      dir -> Path.expand(dir)
    end
  end

  @doc """
  The BUNDLED root, `priv/embed/`: what `mix bl.build` ships, and what a drop
  reads.

  Resolved through `BeamLisp.Tiers.priv_root/0` and not `:code.priv_dir/1`, for
  the reason `BeamLisp.Z3.Port` gives: inside an escript `priv_dir` answers with
  a pseudo-path inside the archive, which is not a directory on disk.
  """
  @spec bundled_root() :: String.t()
  def bundled_root, do: Path.join(BeamLisp.Tiers.priv_root(), "embed")

  @doc "The ambient directory for `name` — where a plain fetch writes."
  @spec ambient_dir(String.t()) :: String.t()
  def ambient_dir(name), do: Path.join(root(), name)

  @doc "The bundled directory for `name` — where `bl install embed` writes."
  @spec bundled_dir(String.t()) :: String.t()
  def bundled_dir(name), do: Path.join(bundled_root(), name)

  @doc """
  The directory to READ `name` from: the first tier that holds a complete copy
  (see the moduledoc for the order and why each tier earns its place).

  Falls back to the ambient directory when NOTHING is fetched, so a caller's
  error message can name where a fetch was expected to land.
  """
  @spec dir(String.t()) :: String.t()
  def dir(name) do
    case System.get_env(@env_dir) do
      dir when is_binary(dir) ->
        Path.join(Path.expand(dir), name)

      nil ->
        Enum.find([bundled_dir(name), ambient_dir(name)], &fetched?/1) || ambient_dir(name)
    end
  end

  @doc """
  Which tier answers `dir/1` for `name`: `:env`, `:bundled`, `:ambient`, or
  `:absent` when no tier holds a complete copy.

  A diagnostic, so a person or a test names the copy in use instead of inferring
  it from whichever directory happened to come back.
  """
  @spec tier(String.t()) :: :env | :bundled | :ambient | :absent
  def tier(name) do
    case System.get_env(@env_dir) do
      dir when is_binary(dir) ->
        if fetched?(Path.join(Path.expand(dir), name)), do: :env, else: :absent

      nil ->
        cond do
          fetched?(bundled_dir(name)) -> :bundled
          fetched?(ambient_dir(name)) -> :ambient
          true -> :absent
        end
    end
  end

  @doc """
  The directories `dir/1` consults, in order — for a message that must not lie
  about where the weights were looked for.
  """
  @spec searched_dirs(String.t()) :: [String.t()]
  def searched_dirs(name), do: Enum.uniq([bundled_dir(name), ambient_dir(name)])

  @doc """
  The files the reader opens, in the order the fetch writes them: what makes a
  directory a model at all.

  Here and not in the fetch task or in `code.embed` because it is the SHAPE of a
  model, which is this module's business: the fetch task owns the pin (these
  names → sha256), the reader owns what to do with the bytes, and "is this copy
  complete?" must be the same question in all three. It was three lists once,
  and a `DIGEST` with no weights beside it read as a complete model.
  """
  @spec files() :: [String.t()]
  def files, do: ~w(config.json tokenizer.json model.safetensors)

  @doc """
  Whether `dir` holds a COMPLETE fetched copy: the `DIGEST` file the fetch task
  writes LAST, after every weight has verified against its pinned sha256, AND
  the files that digest stands for.

  The digest is the identity — it is what every stored embedding records, so a
  copy without one has no provenance — and the files are the substance: a
  `DIGEST` alone is not a model, it is a claim about weights that are not there.
  Both halves are required, because a directory that passes this and cannot be
  read is worse than an absent one: the caller stops looking, and the failure
  surfaces later as a parse error instead of as "not on disk".
  """
  @spec fetched?(String.t()) :: boolean()
  def fetched?(dir) do
    File.regular?(Path.join(dir, "DIGEST")) and Enum.all?(files(), &File.regular?(Path.join(dir, &1)))
  end

  @doc "The env var that overrides `root/0`."
  @spec dir_env() :: String.t()
  def dir_env, do: @env_dir
end
