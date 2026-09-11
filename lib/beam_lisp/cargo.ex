defmodule BeamLisp.Cargo do
  @moduledoc false
  # Where cargo actually puts what it builds.
  #
  # Ask, never assume. A `CARGO_TARGET_DIR`, a `build.target-dir` in ANY
  # `.cargo/config.toml` — the user-level `~/.cargo/config.toml` included — or
  # a workspace all redirect the target directory, and a hardcoded guess fails
  # in the most confusing way available: cargo reports success, and the very
  # next step cannot find the artefact it just built.
  #
  # That is not hypothetical. `bl.build` shipped with this workstation's shared
  # `~/.cache/cargo-target` baked in, so every CI runner — where cargo had
  # correctly written to `tooling/drop/target` — died with "drop tool not found
  # ... (cargo build failed?)" *after* a clean, successful cargo build. The
  # native compiler had already learned the same lesson; this module is that
  # lesson with one implementation instead of two.

  @doc "cargo's target directory for the crate rooted at `crate_dir`."
  def target_dir(crate_dir) do
    case System.cmd("cargo", ["metadata", "--format-version", "1", "--no-deps"],
           cd: crate_dir,
           stderr_to_stdout: true
         ) do
      {json, 0} ->
        # A hand-rolled extraction, because pulling in a JSON dependency for
        # one field would be a poor trade. The key appears once.
        case Regex.run(~r/"target_directory"\s*:\s*"([^"]+)"/, json) do
          [_, dir] -> dir
          _ -> Path.join(crate_dir, "target")
        end

      _ ->
        Path.join(crate_dir, "target")
    end
  end

  @doc "The `release` profile directory under `crate_dir`'s target dir."
  def release_dir(crate_dir), do: Path.join(target_dir(crate_dir), "release")

  @doc """
  The cdylib cargo produced for `crate`, or nil if none is there.

  `release_dir` is the directory to look in (`release_dir/1`). cargo names a
  cdylib per platform — `lib<x>.so`, `lib<x>.dylib`, `<x>.dll` — so probe the
  closed set rather than parse cargo's JSON artifact messages. Probing is also
  what makes the macOS arm reachable from a test on any host.
  """
  def built_cdylib(release_dir, crate) do
    Enum.find(
      [
        Path.join(release_dir, "lib#{crate}.so"),
        Path.join(release_dir, "lib#{crate}.dylib"),
        Path.join(release_dir, "#{crate}.dll")
      ],
      &File.exists?/1
    )
  end

  @doc """
  The executable `name` cargo produced, or nil if none is there.

  Windows appends `.exe`; every other platform does not.
  """
  def built_bin(release_dir, name) do
    Enum.find([Path.join(release_dir, name), Path.join(release_dir, name <> ".exe")], &File.exists?/1)
  end
end
