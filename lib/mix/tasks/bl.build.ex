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
    2. `mix release bl` (prod)               — the ERTS-carrying release tree
    3. `cargo build --release` in tooling/drop — the launcher + pack tool
    4. `drop pack`                           — graft launcher + payload + trailer
    5. install to `--out` (default ./bl)     — atomic rename

  Options:
    * `--out PATH`     where to write the `bl` binary (default `./bl`)
    * `--release DIR`  reuse an existing release tree (skip step 2)
    * `--skip-cargo`   reuse a previously built launcher/pack tool
    * `--target T`     cross-target (`linux/x86_64` etc.; needs per-target NIFs)

  The escript (`mix escript.build`) remains for now as a legacy path; it is
  **deprecated** — it cannot carry NIFs (z3/datom), and cold-loads its archive
  in tens of seconds. Prefer `mix bl.build`.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [out: :string, release: :string, skip_cargo: :boolean, target: :string]
      )

    out = Path.expand(opts[:out] || "./bl")
    drop_dir = Path.join(File.cwd!(), "tooling/drop")
    cargo_target = System.get_env("CARGO_TARGET_DIR") || Path.expand("~/.cache/cargo-target")
    drop_bin = Path.join([cargo_target, "release", "drop"])

    # 1. compile
    Mix.shell().info("bl.build: compiling…")
    Mix.Task.run("compile", [])

    # 2. release (unless reusing one)
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

    # 3. cargo build the launcher + pack tool
    unless opts[:skip_cargo] do
      Mix.shell().info("bl.build: building drop launcher + pack tool…")
      {_, 0} = cmd("cargo", ["build", "--release"], cd: drop_dir)
    end

    unless File.exists?(drop_bin) do
      Mix.raise("bl.build: drop tool not found at #{drop_bin} (cargo build failed?)")
    end

    # 4. pack
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

    # 5. atomic install
    File.rename!(tmp_out, out)
    _ = File.chmod(out, 0o755)

    size_mb = (File.stat!(out).size / 1_048_576) |> Float.round(1)
    Mix.shell().info("bl.build: wrote #{out} (#{size_mb} MB)")
    Mix.shell().info("bl.build: run it with `#{out} version`; start a warm loop with `#{out} daemon start`")
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
