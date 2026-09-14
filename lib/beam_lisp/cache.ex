defmodule BeamLisp.Cache do
  @moduledoc """
  Where derived beam-lisp state lives: two tiers, one rule.

  * **the project cache** — `<project>/.local/bl/cache`, beside the other
    per-checkout state (`.local/blrun`, `.local/bltest`). Derived from a tree,
    it is kept with it, deleted with it, and never read by another checkout.
  * **the host cache** — `$XDG_CACHE_HOME/beam_lisp/cache/<tree id>`, for a
    project that cannot be written to: an installed drop, a mounted checkout, a
    CI read-only bind. Addressed by the same 16-hex tree id a `bl` daemon uses,
    so re-extracting the same payload finds the same directory again instead of
    paying for the analysis twice.

  A *project* is the nearest ancestor of the corpus that looks like one: a
  version-control root (`.git`, `.hg`) or a beam-lisp tree (`mix.exs`,
  `priv/boot/core.bl`, or an extracted drop's `bin/bl` + `releases/`). With no
  such ancestor — a scratch directory of `.bl` files, a mounted sample — the
  corpus you pointed at is the project. That floor matters: a walk without it
  climbs to `/`, the one place a cache must never land.

  Elixir owns the filesystem question; beam-lisp owns what to do about the
  answer. `priv/std/codebase.bl` asks here and picks the tier.
  """

  alias BeamLisp.Daemon.Paths

  @markers [".git", ".hg", "mix.exs", "priv/boot/core.bl"]

  @doc """
  The host cache root: `$XDG_CACHE_HOME/beam_lisp` (else `~/.cache/beam_lisp`).

  `:filename.basedir/2` reads the variable PER CALL, so a test — or a fetch
  pointed elsewhere — is obeyed rather than overruled by a value captured at
  load.
  """
  @spec root() :: String.t()
  def root, do: :filename.basedir(:user_cache, ~c"beam_lisp") |> to_string()

  @doc """
  The host-cache directory for the project containing `path`, keyed by that
  project's tree id — the same key the daemon uses, so a drop payload that is
  extracted again keeps its analysis.
  """
  @spec host_dir(String.t()) :: String.t()
  def host_dir(path), do: Path.join([root(), "cache", tree_id(path)])

  @doc "The project-cache directory for the project containing `path`."
  @spec project_dir(String.t()) :: String.t()
  def project_dir(path), do: Path.join([project_root(path), ".local", "bl", "cache"])

  @doc """
  The project root containing `path`: the nearest ancestor that looks like a
  project, else `path` itself (its parent when `path` is a file).
  """
  @spec project_root(String.t()) :: String.t()
  def project_root(path) do
    start = if File.dir?(path), do: Path.expand(path), else: Path.dirname(Path.expand(path))
    walk(start, start)
  end

  @doc "The 16-hex id of the project containing `path` — the daemon's own tree id."
  @spec tree_id(String.t()) :: String.t()
  def tree_id(path), do: Paths.tree_id(project_root(path))

  # --- internals ---

  defp walk(dir, fallback) do
    cond do
      dir in ["/", "."] -> fallback
      project?(dir) -> dir
      true -> walk(Path.dirname(dir), fallback)
    end
  end

  defp project?(dir) do
    Enum.any?(@markers, &File.exists?(Path.join(dir, &1))) or
      (File.exists?(Path.join([dir, "bin", "bl"])) and File.dir?(Path.join(dir, "releases")))
  end
end
