defmodule Mix.Tasks.Bl.Build do
  @shortdoc "Build the blessed `bl` — a self-contained drop bundle"

  @moduledoc """
  `mix bl.build` — the one command that produces the distributable `bl`.

  The `bl` you ship is a **drop**: a self-extracting bundle carrying ERTS + the
  full native tier (language + datom crates + z3 + Explorer). It runs with no
  Erlang installed, and its launcher attaches to a warm `bl daemon` for a
  ~instant dev loop, falling back to a ~1s cold boot when none is up.

  This task chains, in order:

    1. `mix compile`                         — the beams, AOT prelude, NIFs
    2. `mix bl.embed.fetch --bundle`         — the pinned embedding weights
    3. `mix release bl` (prod)               — the ERTS-carrying release tree
    4. `cargo build --release` in tooling/drop — the launcher + pack tool
    5. `drop pack`                           — graft launcher + payload + trailer
    6. install to `--out` (default ./bl)     — atomic rename

  Options:
    * `--out PATH`     where to write the `bl` binary (default `./bl`)
    * `--release DIR`  reuse an existing release tree (skip step 3)
    * `--skip-cargo`   reuse a previously built launcher/pack tool
    * `--target T`     cross-target (`linux/x86_64` etc.; needs per-target NIFs)
    * `--no-embed`     build WITHOUT the embedding weights. The drop is then
      ~33 MB smaller and `bl search` needs `mix bl.embed.fetch` on the machine
      that runs it — which a user of a drop cannot do. The weights are part of
      the default distribution on purpose: the drop carries no Mix and no
      network assumption, and a capability that ships absent reads as a bug.

  The escript path is **removed** (no `escript:` in mix.exs): an escript is a
  single BEAM archive with no way to carry native artifacts (z3/datom NIFs,
  Explorer/Polars, drop-packed binaries), so it can never package a full
  beam-lisp. `mix release` — which this task wraps — is the only supported
  packaging tier: it carries ERTS + priv/ + the native tier. `mix bl.build`
  is the one command that produces a shippable `bl`.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [out: :string, release: :string, skip_cargo: :boolean, target: :string, embed: :boolean]
      )

    out = Path.expand(opts[:out] || "./bl")
    drop_dir = Path.join(File.cwd!(), "tooling/drop")

    # 1. compile
    Mix.shell().info("bl.build: compiling…")
    Mix.Task.run("compile", [])

    # 2. the embedding, BEFORE the release copies priv/ into the payload: a
    #    release packed without the weights cannot be fixed by packing harder.
    #    The fetch is idempotent and sha256-verified per file, so a warm
    #    priv/embed costs one digest check and no network.
    unless opts[:embed] == false do
      Mix.shell().info("bl.build: fetching the code-embedding weights…")
      Mix.Task.run("bl.embed.fetch", ["--bundle"])
      Mix.shell().info("bl.build: embedding bundled: #{Float.round(bundled_bytes() / 1_048_576, 1)} MB")
    end

    # 3. release (unless reusing one)
    release_dir =
      case opts[:release] do
        nil ->
          rel_path = Path.join(System.tmp_dir!(), "bl-release-#{:os.getpid()}")
          Mix.shell().info("bl.build: building prod release → #{rel_path}…")
          {_, 0} = cmd("mix", ["release", "bl", "--overwrite", "--path", rel_path], env: [{"MIX_ENV", "prod"}])
          rel_path

        dir ->
          Mix.shell().info("bl.build: reusing release #{dir}")
          dir
      end

    # 4. cargo build the launcher + pack tool
    unless opts[:skip_cargo] do
      Mix.shell().info("bl.build: building drop launcher + pack tool…")
      {_, 0} = cmd("cargo", ["build", "--release"], cd: drop_dir)
    end

    # Ask cargo where it put them. Assuming a target dir (this task once
    # hardcoded this workstation's shared `~/.cache/cargo-target`) reports a
    # perfectly successful cargo build as a missing tool on every runner.
    cargo_release = BeamLisp.Cargo.release_dir(drop_dir)
    drop_bin = BeamLisp.Cargo.built_bin(cargo_release, "drop")

    if is_nil(drop_bin) do
      Mix.raise("bl.build: drop tool not found in #{cargo_release} (cargo build failed?)")
    end

    # 5. pack
    tmp_out = out <> ".tmp"
    pack_args =
      ["pack", "--release", release_dir, "--out", tmp_out] ++
        case opts[:target] do
          nil -> []
          t -> ["--target", t, "--erts", "auto"]
        end

    Mix.shell().info("bl.build: packing drop…")
    {packout, packstatus} = System.cmd(drop_bin, pack_args, stderr_to_stdout: true)
    if packstatus != 0, do: Mix.raise("bl.build: drop pack failed:\n#{packout}")
    Mix.shell().info(String.trim_trailing(packout))

    # 6. atomic install
    File.rename!(tmp_out, out)
    _ = File.chmod(out, 0o755)

    size_mb = (File.stat!(out).size / 1_048_576) |> Float.round(1)
    Mix.shell().info("bl.build: wrote #{out} (#{size_mb} MB)")
    Mix.shell().info("bl.build: run it with `#{out} version`; start a warm loop with `#{out} daemon start`")
  end

  # Bytes under `priv/embed/` — what the embedding adds to the drop, said in
  # the units a person sizing a download thinks in.
  defp bundled_bytes do
    BeamLisp.Model.bundled_root()
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&File.stat!(&1).size)
    |> Enum.sum()
  end

  # Run a command, streaming output; return {output, exit_status}.
  defp cmd(bin, args, opts) do
    env = Keyword.get(opts, :env, [])
    cd = Keyword.get(opts, :cd, File.cwd!())

    System.cmd(bin, args,
      cd: cd,
      env: env,
      stderr_to_stdout: true,
      into: IO.stream(:stdio, :line)
    )
  rescue
    e -> Mix.raise("bl.build: #{bin} failed: #{Exception.message(e)}")
  end
end
