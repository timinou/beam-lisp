defmodule BeamLisp.Tiers do
  @moduledoc """
  The tiers of beam-lisp's own source tree under `priv/`.

  Every shipped namespace lives in exactly one tier, and the tier says how a
  change to it propagates through the AOT build:

    * `boot/` — the CODEGEN: the self-hosted reader and compiler, the
      ambient prelude every namespace resolves against (`core`, `sugar`), the
      tagged-literal registry (`data-readers`), and the Core-Erlang backend
      (`anf`, `lower`).

      These run at compile time for EVERY namespace, so a change here
      rotates `BeamLisp.AOTCache.compiler_key/0` and rebuilds all beams.
    * `build/` — the BUILD DRIVER: `build`, `build-plan`, `source-graph`,
      `ns-interface`. None of these can change an emitted byte, so folding them
      into the codegen key made every build-tool edit invalidate the whole tree
      — a full prelude rebuild to change a scheduler. They carry their own key,
      `BeamLisp.AOTCache.build_key/0`: the driver's sources plus
      `compiler_key/0`, since the driver is compiled BY the codegen. They are
      also the namespaces the drift gate itself runs on, so they can never be
      vetted by closure hash — asking for `build-plan`'s closure would ask the
      gate to load what it is vetting. A tier key is the only sound answer.
    * `std/` — the standard library: `env`, `errors`, `multi`, `typed`,
      `test`, `reload`, the `bl` CLI… Keyed per namespace: editing one file
      rebuilds only its require-closure.
    * `lib/` — batteries: `datom`, `auth`, `live`, `loom`, `veritas`, `z3`,
      `system`… Same per-namespace keying; optional in a release.
    * `compat/` — Clojure/Babashka stdlib compatibility: `clojure.string`,
      `clojure.set`, `clojure.walk`, `clojure.edn`, regex helpers, IO. Native
      reimplementations exposing the upstream public API so unmodified Clojure
      source loads and runs. Per-namespace keyed; optional in a release.

  `self/` holds the self-hosting gates (oracle, fixpoint) — never a library a
  program requires. `build/` is a library tier only in that the driver requires
  its own modules (`build` → `build-plan` → `source-graph`); no program under
  `std/`, `lib/` or `compat/` may reach into it.
  """

  @tiers ~w(boot std lib compat build self)
  @library_tiers ~w(boot std lib compat build)

  @doc "Tier directory names, in load-path order."
  def names, do: @tiers

  @doc "Tiers whose namespaces a program may require (excludes `self/`)."
  def library_names, do: @library_tiers

  @doc "Absolute tier directories under the app's `priv/`, existing ones only."
  def dirs(root \\ priv_root()) do
    @library_tiers
    |> Enum.map(&Path.join(root, &1))
    |> Enum.filter(&File.dir?/1)
  end

  @doc "The `boot/` directory: the CODEGEN tier the compiler key hashes."
  def boot_dir(root \\ priv_root()), do: Path.join(root, "boot")
  @doc """
  The `build/` directory: the build DRIVER tier, hashed into its own key.

  Distinct from `boot/` on purpose. A namespace here decides WHAT to build and
  cannot change an emitted byte, so a change to one must not invalidate every
  beam in the tree. See the moduledoc.
  """
  def build_dir(root \\ priv_root()), do: Path.join(root, "build")
  @doc """
  Namespaces of the boot tier — the file basenames under `priv/boot/`, which
  is also their declared ns (the tier is flat). Memoised in `:persistent_term`:
  the AOT drift gate asks on every load, and the tier's membership is a
  constant of the checkout.
  """
  def boot_namespaces, do: tier_namespaces(:boot)

  @doc "Namespaces of the build tier — file basenames under `priv/build/`. Memoised."
  def build_namespaces, do: tier_namespaces(:build)

  defp tier_namespaces(tier) do
    key = {__MODULE__, :namespaces, tier}

    case :persistent_term.get(key, nil) do
      nil ->
        names =
          priv_root()
          |> Path.join(Atom.to_string(tier))
          |> Path.join("*.bl")
          |> Path.wildcard()
          |> Enum.map(&Path.basename(&1, ".bl"))

        :persistent_term.put(key, names)
        names

      names ->
        names
    end
  end

  @doc """
  Which tier a namespace's freshness key comes from.

    * `:boot` — codegen: `BeamLisp.AOTCache.compiler_key/0`
    * `:build` — the driver: `BeamLisp.AOTCache.build_key/0`
    * `:library` — everything else: the interface closure plus `compiler_key/0`
  """
  def tier_of_ns(ns) when is_binary(ns) do
    cond do
      ns in boot_namespaces() -> :boot
      ns in build_namespaces() -> :build
      true -> :library
    end
  end

  @doc """
  Whether a source belongs to the boot tier (codegen), including Mix's priv
  symlink.

  `root` is which priv the question is about, and it exists because a build can
  run over a STAGED copy of a priv rather than the running one — a self-build
  stages the payload's sources so that the paths compiled into beams are stable
  from generation to generation. Without an explicit root every staged source
  would read as ordinary, and the driver's own beams would lose the tier key the
  drift gate depends on.
  """
  def boot_source?(path, root \\ priv_root()), do: source_beneath?(boot_dir(root), path)

  @doc "Whether a source belongs to the build-driver tier, relative to `root`."
  def build_source?(path, root \\ priv_root()), do: source_beneath?(build_dir(root), path)

  @doc """
  Whether a source is a TOOLCHAIN source: codegen (`boot/`) or driver
  (`build/`). These build serially before the ordinary waves — the compiler
  and the program scheduling it must both be sound before anything else runs.
  """
  def toolchain_source?(path, root \\ priv_root()),
    do: boot_source?(path, root) or build_source?(path, root)

  defp source_beneath?(dir, path) do
    with {:ok, stat} <- File.stat(dir) do
      beneath_directory?(Path.dirname(Path.expand(path)), {stat.major_device, stat.inode})
    else
      _ -> false
    end
  end

  defp beneath_directory?(path, identity) do
    case File.stat(path) do
      {:ok, stat} when {stat.major_device, stat.inode} == identity -> true
      _ ->
        parent = Path.dirname(path)
        parent != path and beneath_directory?(parent, identity)
    end
  end

  @doc "Every `.bl` source under the library tiers, sorted."
  def sources(root \\ priv_root()) do
    root
    |> dirs()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.bl")))
    |> Enum.sort()
  end

  @doc """
  beam-lisp's `priv/` directory. Prefers the code path (works in releases),
  falling back to the source tree relative to this file (escripts, flat
  deployments, the compile task's VM before the app is loaded).
  """
  def priv_root do
    # An escript answers `priv_dir` with a path INSIDE its archive — a path no
    # `File`/`Path.wildcard` call can see. Treat a priv dir that is not a real
    # directory as absent and fall back to the source tree: otherwise
    # `boot_namespaces/0` reads as `[]`, the drift gate asks `build-plan` for a
    # key while `build-plan` is the namespace being loaded, the loader's cycle
    # guard answers "already loading", and the escript dies at boot with
    # `undefined var: build-plan/key-for`.
    case :code.priv_dir(:beam_lisp) do
      dir when is_list(dir) ->
        dir = List.to_string(dir)
        if File.dir?(dir), do: dir, else: Path.expand("../../priv", __DIR__)

      _ ->
        Path.expand("../../priv", __DIR__)
    end
  end
end
