defmodule Mix.Tasks.Compile.BeamLispNative do
  @moduledoc """
  Build the Rust crates that `defnative` namespaces load.

  ## Why this exists

  Rustler's own Mix integration is driven by `use Rustler` inside an
  Elixir module. `defnative` removes that module — a beam-lisp namespace
  hosts its NIF directly — so nothing was left to trigger the build.

  Deleting the last `use Rustler` was therefore silently load-bearing:
  the checked-in `.so` kept working until it was deleted, and then the
  NIF simply stopped existing with no error anywhere except
  `available?` answering false.

  This task closes that gap. It compiles every crate under `native/` and
  installs the result where `BeamLisp.Native` looks for it.

  ## Absent toolchain

  A checkout without `cargo` is not an error. The database runs on its
  in-memory stores, `available?` answers false, and the conformance
  suite drops the native backend from its list rather than failing. A
  native capability that cannot be built must read as ABSENT, never as
  present-but-broken — so this task warns and succeeds.
  """

  use Mix.Task.Compiler

  @native_dir "native"

  @impl Mix.Task.Compiler
  def run(_args) do
    if File.dir?(@native_dir) do
      case System.find_executable("cargo") do
        nil ->
          Mix.shell().info([
            :yellow,
            "no cargo on PATH — native backends will report unavailable"
          ])

          {:ok, []}

        _cargo ->
          @native_dir
          |> File.ls!()
          |> Enum.filter(&File.exists?(Path.join([@native_dir, &1, "Cargo.toml"])))
          |> Enum.each(&build/1)

          {:ok, []}
      end
    else
      {:ok, []}
    end
  end

  defp build(crate) do
    crate_dir = Path.join(@native_dir, crate)
    Mix.shell().info([:green, "Compiling NIF ", :reset, crate])

    # No RUSTFLAGS here: each crate carries its own `.cargo/config.toml`
    # with the linker flags a NIF needs (undefined symbols resolve
    # against the host VM at load time). Setting the env var OVERRIDES
    # that file rather than adding to it, which silently changed the
    # build fingerprint and left cargo reporting "Finished" while
    # producing nothing.
    case System.cmd("cargo", ["build", "--release"],
           cd: crate_dir,
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        install(crate, crate_dir)

      {out, code} ->
        # A crate that fails to COMPILE is a real error — the source is
        # there and broken, which is different from a toolchain that is
        # absent. Failing loudly here is what keeps a syntax error in
        # Rust from surfacing later as a mysterious `nif_not_loaded`.
        Mix.raise("cargo build failed for #{crate} (exit #{code}):\n#{out}")
    end
  end

  defp target_dir(crate_dir) do
    case System.cmd("cargo", ["metadata", "--format-version", "1", "--no-deps"],
           cd: crate_dir,
           stderr_to_stdout: true
         ) do
      {json, 0} ->
        # A hand-rolled extraction, because pulling in a JSON dependency
        # for one field would be a poor trade. The key appears once.
        case Regex.run(~r/"target_directory"\s*:\s*"([^"]+)"/, json) do
          [_, dir] -> dir
          _ -> Path.join(crate_dir, "target")
        end

      _ ->
        Path.join(crate_dir, "target")
    end
  end

  defp install(crate, crate_dir) do
    # ASK cargo where it put the artifact rather than assuming
    # `<crate>/target`. A `CARGO_TARGET_DIR` in the environment (or a
    # workspace, or `.cargo/config.toml`) redirects it elsewhere — on
    # this machine to a shared `~/.cache/cargo-target` — and the
    # assumption failed in the most confusing way available: cargo
    # reported success, and the copy then failed on a path that had
    # never existed.
    #
    # cargo names a cdylib `lib<name>.so`; the BEAM wants
    # `priv/native/<name>` (no prefix, and `load_nif` appends the
    # extension).
    built = Path.join([target_dir(crate_dir), "release", "lib#{crate}.so"])

    unless File.exists?(built) do
      Mix.raise("""
      cargo reported success but produced no #{built}.

      Most likely the crate is not configured as a cdylib. Its
      Cargo.toml needs:

          [lib]
          crate-type = ["cdylib"]
      """)
    end

    dest_dir = Path.join("priv", "native")
    File.mkdir_p!(dest_dir)

    # `BeamLisp.Native` loads `priv/native/<crate>` (no `lib` prefix,
    # no extension — `:erlang.load_nif/2` appends it).
    File.cp!(built, Path.join(dest_dir, "#{crate}.so"))
  end
end
