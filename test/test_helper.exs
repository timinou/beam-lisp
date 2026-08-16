# Tests tagged `:verse` shell out to the `spacetime` compiler. It is a separate
# checkout, built with cargo, and it is legitimately absent on a machine that
# only works on the BEAM side.
#
# The gate is here rather than inside each test on purpose. A test that checks
# for the binary and returns early PASSES when the toolchain is missing, and a
# missing checker reading as a clean check is the worst failure a checker has
# available — `BeamLisp.Spell.Verse.check/1` documents the same lesson about
# its own exit-code handling. Excluding the tag makes ExUnit report them as
# EXCLUDED, with the reason printed once, so the number on screen never claims
# more than was run.
case BeamLisp.Spell.Verse.binary() do
  {:ok, _path} ->
    ExUnit.start()

  {:error, reason} ->
    IO.puts(:stderr, """

    ── spacetime not available: rungs 3–4 are EXCLUDED, not passed ──────────
    #{reason}
    Run `mix test --include verse` after building it to exercise them.
    ────────────────────────────────────────────────────────────────────────
    """)

    ExUnit.start(exclude: [:verse])
end
