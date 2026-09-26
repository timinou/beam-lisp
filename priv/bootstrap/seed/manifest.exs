# beam-lisp bootstrap seed manifest — generated, do not edit by hand.
# Regenerate: bl seed (after a keyed build).
%{
  "app" => %{
    "file" => "beam_lisp.app",
    "sha256" => "868221a5f42922ca01a126204ac0440406751eee3c0b7939abdcab9f60ff614d"
  },
  "build_key" => "9c1ca5bb3e35706a86df0515190ff78f34b315286cd3d1c1696e6d505f633237",
  "compiler_key" => "22fea102f53c8aeb55ad0d51007118067a45057faf064847007796c8a8421c40",
  "elixir" => "1.20.2",
  "modules" => %{
    "Elixir.BeamLisp.CompilerData.beam" => "4d6f2c75669a9a44413e15f80a80121b8031a5f59c30477294da09660727a356",
    "Elixir.BeamLisp.Emit.beam" => "122ca2410fdbae59047d384bc7a00141486cd167afea749adbf81ccbaa0b9de7",
    "Elixir.BeamLisp.Link.beam" => "596176218b92cf546c5a768c795c9987f392e9ad731449be64b6dfd248ce592e",
    "Elixir.BeamLisp.Ns.Anf.beam" => "43d7f4e1913320d9cb944476ecc63ef7563a6d3923f03fdee65b2c332fd0c067",
    "Elixir.BeamLisp.Ns.Body.Anf.beam" => "bdad474b71f8a98b808da4c96d6977ad50b0b9c967e746926db31e5e1ba9ac62",
    "Elixir.BeamLisp.Ns.Body.Compiler.beam" => "64d9ffd813623ef61f77bb0b08a6c6b528e6d4b3adb7d820e5a5753d7cefb038",
    "Elixir.BeamLisp.Ns.Body.Core.beam" => "a2e21ed283ed8fd414de3e606a5fe2011667da7f8ad7c9d20769ead4a338df9b",
    "Elixir.BeamLisp.Ns.Body.Diag.beam" => "5d688135c59fcae590d3dec8a79152ad0d368dd449ab5941d3d95837f93d0238",
    "Elixir.BeamLisp.Ns.Body.Lower.beam" => "096a078d908e91a0a74cec8820a898895b118bea738160e09cd57d4a27ab0aa5",
    "Elixir.BeamLisp.Ns.Body.Multi.beam" => "ad56c68b1f4104c5dfaecca21bc4e6388e2a8473cf8216b15876f8b0df3b7e49",
    "Elixir.BeamLisp.Ns.Body.Reader-node.beam" => "8918febfab0e8426e548da9d9428fc74db9ad3f941bf28b738dbf313a3ec99ed",
    "Elixir.BeamLisp.Ns.Body.Reader.beam" => "61988fa5c254de7e3740b73888e905a9988a30d78639ee096180e36d9f3f2f1c",
    "Elixir.BeamLisp.Ns.Body.Rt.beam" => "fc3e4f4f1cdc186fe11ca39c35c994bdd245e66bb4a53797789766663bd0854d",
    "Elixir.BeamLisp.Ns.Body.Sugar.beam" => "2c19474b571964728495d243368519deda4681efd909ce5a81c295122d662c93",
    "Elixir.BeamLisp.Ns.Compiler.beam" => "6d81a27b3bff0eec778998a27eb23a963bf916b590d47602d573e6213878433e",
    "Elixir.BeamLisp.Ns.Core.beam" => "9a99ec3b4a9376f00d3302a3396c9616b1d3b25697bb577cd8d7c5671ac08523",
    "Elixir.BeamLisp.Ns.Diag.beam" => "7824fd7d8b29118f2ff5ecfd76c03455f674774ced469bdc94912def943013d6",
    "Elixir.BeamLisp.Ns.Init.Anf.beam" => "11d38a294bb9261173973d8febc14acf8b76821b157e144751b6e7c16616cad7",
    "Elixir.BeamLisp.Ns.Init.Compiler.beam" => "b8dad9b4bd9c8ce6f1b5cfc1423e3250fdfb1b83adfad9f1a8e9a3c420fdf6c2",
    "Elixir.BeamLisp.Ns.Init.Core.beam" => "a4acb0da65aab56c7d9279a00571c6738d141bc480e724c3749212a6904ffbfc",
    "Elixir.BeamLisp.Ns.Init.Diag.beam" => "33a5874d46925f0a89ebec891cd9ecac44a058ee8b6896ab6fa2b739bdad8a00",
    "Elixir.BeamLisp.Ns.Init.Reader.beam" => "c71406bd8e7cd39fccefb296659823e4f16657166cad877563eb89663aeffbd0",
    "Elixir.BeamLisp.Ns.Init.Rt.beam" => "d38c1c133952ed9c01636474aad5d391183e45736ae5a7cd9c7f23d8870b905d",
    "Elixir.BeamLisp.Ns.Init.Sugar.beam" => "9c432e79e91a7fd094ea447a850db6d27065df49b53757aff20e4f3a473866a9",
    "Elixir.BeamLisp.Ns.Lower.beam" => "c71601b663dc5248074387c48e722093e9ecf61246dd863ef02c3f1b5ff69f75",
    "Elixir.BeamLisp.Ns.Multi.beam" => "d4c192071f0f9659742c1c05cc6e3763c22297964b36d4405c25fe0d204d5569",
    "Elixir.BeamLisp.Ns.Reader-node.beam" => "0afa0298c59a3af1e228e34db3426f01f8dd1c0b06944323db114e48d22e5828",
    "Elixir.BeamLisp.Ns.Reader.beam" => "6d74582a20f315fc329c397bde2cb6c514af6955538558a24313d1bb4863b1cd",
    "Elixir.BeamLisp.Ns.Rt.beam" => "3967c272eed133f8021b511ef08f23b2010c0353abd0bfe302e34a6106f1ebdc",
    "Elixir.BeamLisp.Ns.Sugar.beam" => "4bd69fdceec507f3dbc431dc75be8e47ea35f1c11791800b26216936b8af4305",
    "Elixir.BeamLisp.Tiers.beam" => "bf06d617e5c4ffbb6fe31023e8a5d59c8cc1d39d3bb3c767270b6b5cb2f7c17c"
  },
  "otp" => "29",
  "schema" => "beam-lisp-bootstrap-seed-v2"
}
