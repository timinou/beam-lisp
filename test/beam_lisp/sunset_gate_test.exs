defmodule BeamLisp.SunsetGateTest do
  @moduledoc """
  The FUP-082 sunset gate: modules whose POLICY has moved to beam-lisp must not
  reappear in `lib/` as Elixir. This test fails loudly the moment a deleted
  module's name is defined again — the boundary cannot erode silently.

  Grows one entry per cutover stage:
    * PLAN-122 (T3/native): BeamLisp.Native, BeamLisp.NativeTask, BeamLisp.Cargo
    * PLAN-123 (T2/daemon): BeamLisp.Daemon.* (added when that stage lands)
  """
  use ExUnit.Case, async: true

  # Module names that have been sunset — their policy is now beam-lisp.
  # A `defmodule <name>` under lib/ for any of these is a regression.
  @sunset_modules [
    # PLAN-122 (T3/native)
    "BeamLisp.Native",
    "BeamLisp.NativeTask",
    "BeamLisp.Cargo",
    # PLAN-123 + FUP-085 (T2/daemon + the routing edge): the WHOLE daemon is
    # beam-lisp now (priv/std/vm/*.bl). No BeamLisp.Daemon.* may return.
    "BeamLisp.Daemon",
    "BeamLisp.Daemon.Paths",
    "BeamLisp.Daemon.Names",
    "BeamLisp.Daemon.Ports",
    "BeamLisp.Daemon.Gateway",
    "BeamLisp.Daemon.CA",
    "BeamLisp.Daemon.IndexWorker",
    "BeamLisp.Daemon.Server",
    "BeamLisp.Daemon.Listener",
    "BeamLisp.Daemon.IO",
    "BeamLisp.Daemon.Protocol",
    "BeamLisp.Daemon.Inspect",
    "BeamLisp.Daemon.HTTP",
    "BeamLisp.Daemon.Executor",
    "BeamLisp.Daemon.Workers",
    "BeamLisp.Daemon.WatchRegistry",
    "BeamLisp.Daemon.StdErr"
  ]

  @lib_root Path.expand("../../lib", __DIR__)

  test "no sunset module is defined under lib/" do
    ex_files =
      Path.wildcard(Path.join(@lib_root, "**/*.ex"))

    offenders =
      for file <- ex_files,
          mod <- @sunset_modules,
          defines_module?(file, mod),
          do: {mod, Path.relative_to(file, @lib_root)}

    assert offenders == [],
           "sunset modules re-defined in lib/ (their policy moved to beam-lisp):\n" <>
             Enum.map_join(offenders, "\n", fn {mod, file} -> "  #{mod}  ← #{file}" end) <>
             "\n\nThese were deleted by FUP-082. If you need their behaviour, it lives in " <>
             "priv/std/vm/native.bl — do not re-introduce the Elixir module."
  end

  # A real `defmodule Name do` — not a comment or a string mention. Matches the
  # exact module head at the start of a line (Elixir's own formatting).
  defp defines_module?(file, mod) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.any?(fn line -> Regex.match?(~r/^\s*defmodule\s+#{Regex.escape(mod)}\s+do/, line) end)
  end
  # ── the workaround ecosystem (PLAN-121/123) must not return ──
  #
  # The single serial worker is gone, and so is everything that compensated for
  # it. These tokens naming that scaffolding must not reappear in daemon code —
  # if one does, a serial-worker assumption has crept back in.
  @banned_tokens [
    "owns_process",
    "owns-process?",
    "refuse_owning",
    "Attach::Busy",
    "ready_busy",
    "DaemonMode::Queue",
    "BL_DAEMON=queue"
  ]

  # The daemon is beam-lisp now (priv/std/vm); the token gate still watches the
  # whole runtime + the Rust launcher for a serial-worker assumption creeping back.
  @daemon_src [
    Path.expand("../../priv/std/vm", __DIR__),
    Path.expand("../../lib/beam_lisp", __DIR__),
    Path.expand("../../tooling/drop/src", __DIR__)
  ]

  test "no workaround-ecosystem token reappears in daemon source" do
    files =
      @daemon_src
      |> Enum.flat_map(fn dir -> Path.wildcard(Path.join(dir, "**/*.{ex,rs,bl}")) end)

    offenders =
      for file <- files,
          token <- @banned_tokens,
          line <- lines_with(file, token),
          # allow a comment that documents the REMOVAL (names the token to say
          # it is gone) — only a real code use is a regression.
          not documents_removal?(line),
          do: {token, Path.basename(file), String.trim(line)}

    assert offenders == [],
           "workaround tokens reappeared in daemon source (the serial worker is gone):\n" <>
             Enum.map_join(offenders, "\n", fn {tok, f, l} -> "  #{tok}  ← #{f}: #{l}" end)
  end

  defp lines_with(file, token) do
    file |> File.read!() |> String.split("\n") |> Enum.filter(&String.contains?(&1, token))
  end

  # A line that mentions a token only to say it was removed (a `//` or `#`
  # comment containing "gone", "removed", "no ", "PLAN-121", etc.) is allowed.
  defp documents_removal?(line) do
    trimmed = String.trim(line)
    comment? = String.starts_with?(trimmed, "#") or String.starts_with?(trimmed, "//") or
                 String.starts_with?(trimmed, "///")
    comment? and Regex.match?(~r/gone|removed|no longer|deleted|PLAN-12[13]|there is no|never busy/i, line)
  end

end
