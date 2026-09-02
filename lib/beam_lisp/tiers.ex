defmodule BeamLisp.Tiers do
  @moduledoc """
  The tiers of beam-lisp's own source tree under `priv/`.

  Every shipped namespace lives in exactly one tier, and the tier says how a
  change to it propagates through the AOT build:

    * `boot/` — the toolchain: reader, compiler, `core`, `sugar`, data
      readers. These run at compile time for EVERY namespace, so a change here
      rotates `BeamLisp.AOTCache.compiler_key/0` and rebuilds all beams.
    * `std/` — the standard library: `env`, `errors`, `multi`, `typed`,
      `test`, `reload`, the `bl` CLI… Keyed per namespace: editing one file
      rebuilds only its require-closure.
    * `lib/` — batteries: `datom`, `auth`, `live`, `loom`, `veritas`, `z3`,
      `system`… Same per-namespace keying; optional in a release.

  `self/` holds the self-hosting gates (oracle, fixpoint) and `build/` the
  build system written in beam-lisp; neither is a library a program requires.
  """

  @tiers ~w(boot std lib build self)
  @library_tiers ~w(boot std lib build)

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

  @doc "The `boot/` directory: the toolchain tier the compiler key hashes."
  def boot_dir(root \\ priv_root()), do: Path.join(root, "boot")

  @doc """
  Namespaces of the boot tier — the file basenames under `priv/boot/`, which
  is also their declared ns (the tier is flat). Memoised in `:persistent_term`:
  the AOT drift gate asks on every load, and the tier's membership is a
  constant of the checkout.
  """
  def boot_namespaces do
    key = {__MODULE__, :boot_namespaces}

    case :persistent_term.get(key, nil) do
      nil ->
        names =
          boot_dir()
          |> Path.join("*.bl")
          |> Path.wildcard()
          |> Enum.map(&Path.basename(&1, ".bl"))

        :persistent_term.put(key, names)
        names

      names ->
        names
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
