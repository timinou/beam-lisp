# beam-lisp bootstrap seed manifest — generated, do not edit by hand.
# Regenerate: bl seed (after a keyed build).
%{
  "app" => %{
    "file" => "beam_lisp.app",
    "sha256" => "868221a5f42922ca01a126204ac0440406751eee3c0b7939abdcab9f60ff614d"
  },
  "build_key" => "bfcad8da8a2c9cfcbd5a50118f7234b0bbfbf754d20d21c8cf488be8158ffae5",
  "compiler_key" => "bdfd9f28e523062816831c368628ac9de070d101b8b74ee85c21ae6060c3132c",
  "elixir" => "1.20.2",
  "modules" => %{
    "Elixir.BeamLisp.CompilerData.beam" => "aa73475489d9c976241585b8092e46bdf85d6d994bb9707447a711dfceba693b",
    "Elixir.BeamLisp.Emit.beam" => "85bb5ed2e2de9fcfa0f99e446e18b20efbd3f71388e5fcaeb3d59f787630bbc7",
    "Elixir.BeamLisp.Link.beam" => "476a0805c48e1823fbe596aac566587072c0a9232890d805ed0924fe9eb14cca",
    "Elixir.BeamLisp.Ns.Anf.beam" => "0d64f5475c499d17623c9a360690d6e292aac43dd55976c6e5f5ea9fc508480e",
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
    "Elixir.BeamLisp.Ns.Compiler.beam" => "3353d737da973789d6ff9f6cef19ca4e0f03378a3078513e4bb4c71879ff7ff7",
    "Elixir.BeamLisp.Ns.Core.beam" => "85848ee69549e36c6d09eabd4273a22865e16a66ff85f6c542406679467dd030",
    "Elixir.BeamLisp.Ns.Diag.beam" => "b20a6643749f1ee82631b42d1b1e4579d0989d00353274f0fd4e00368cd269a7",
    "Elixir.BeamLisp.Ns.Init.Anf.beam" => "11d38a294bb9261173973d8febc14acf8b76821b157e144751b6e7c16616cad7",
    "Elixir.BeamLisp.Ns.Init.Compiler.beam" => "b8dad9b4bd9c8ce6f1b5cfc1423e3250fdfb1b83adfad9f1a8e9a3c420fdf6c2",
    "Elixir.BeamLisp.Ns.Init.Core.beam" => "a4acb0da65aab56c7d9279a00571c6738d141bc480e724c3749212a6904ffbfc",
    "Elixir.BeamLisp.Ns.Init.Diag.beam" => "33a5874d46925f0a89ebec891cd9ecac44a058ee8b6896ab6fa2b739bdad8a00",
    "Elixir.BeamLisp.Ns.Init.Reader.beam" => "c71406bd8e7cd39fccefb296659823e4f16657166cad877563eb89663aeffbd0",
    "Elixir.BeamLisp.Ns.Init.Rt.beam" => "d38c1c133952ed9c01636474aad5d391183e45736ae5a7cd9c7f23d8870b905d",
    "Elixir.BeamLisp.Ns.Init.Sugar.beam" => "9c432e79e91a7fd094ea447a850db6d27065df49b53757aff20e4f3a473866a9",
    "Elixir.BeamLisp.Ns.Lower.beam" => "c484f6cc5087ffd2a9e58e3d8bebab5803e19c954b972ebbb67a0603c513d9ce",
    "Elixir.BeamLisp.Ns.Multi.beam" => "3dee9dc0d22bce94d07ce8d602505d9b0377711fa4ab8cb13f2a81fadc3f42d1",
    "Elixir.BeamLisp.Ns.Reader-node.beam" => "cb0011fd008eb5f54f14511d3fe8f0b6c6c52adcba420bd8491830e5e15144a1",
    "Elixir.BeamLisp.Ns.Reader.beam" => "b08261e060f62adda6a0dabf0f9a6ea79331a47cd4d63b5e090e62ef6271a894",
    "Elixir.BeamLisp.Ns.Rt.beam" => "0d3400cdca5184c6e0fe072a9df95c105f5686e0edc8454a78d7170dbeea4653",
    "Elixir.BeamLisp.Ns.Sugar.beam" => "3984c802dd14ffbf0e6a079cd381de246f89204333a927ba0c7ffadf3dfbf908"
  },
  "otp" => "29",
  "schema" => "beam-lisp-bootstrap-seed-v2"
}
