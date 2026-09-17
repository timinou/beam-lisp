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
    "BeamLisp.Native",
    "BeamLisp.NativeTask",
    "BeamLisp.Cargo"
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
end
