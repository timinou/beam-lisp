ExUnit.start()

# Boot-tier toolchain iteration without a seed regen: BL_HOTPATCH=anf,lower
# recompiles those priv/boot/*.bl namespaces from current source and swaps
# them into this test VM. See BeamLisp.DevHotpatch.
BeamLisp.DevHotpatch.apply_env!()
