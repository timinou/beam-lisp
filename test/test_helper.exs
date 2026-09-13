# `autorun: false`: ExUnit's at-exit run would report a SECOND, empty result after
# the runner's own (both `mix test` and `bl test` run ExUnit explicitly), and an
# exit runs at_exit hooks — so the number printed last would be the wrong one.
ExUnit.start(autorun: false)

# Boot-tier toolchain iteration without a seed regen: BL_HOTPATCH=anf,lower
# recompiles those priv/boot/*.bl namespaces from current source and swaps
# them into this test VM. See BeamLisp.DevHotpatch.
BeamLisp.DevHotpatch.apply_env!()
