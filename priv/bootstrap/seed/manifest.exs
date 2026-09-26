# beam-lisp bootstrap seed manifest — generated, do not edit by hand.
# Regenerate: bl seed (after a keyed build).
%{
  "app" => %{
    "file" => "beam_lisp.app",
    "sha256" => "868221a5f42922ca01a126204ac0440406751eee3c0b7939abdcab9f60ff614d"
  },
  "build_key" => "8abcec654167a028bf75ef76760cb278a0919bdb9a06f69758f7fe9386d3a3b9",
  "compiler_key" => "a764973966a65dffff80dd4c11ed526bb609360df63bd397f134df25ad07f603",
  "elixir" => "1.20.2",
  "modules" => %{
    "Elixir.BeamLisp.CompilerData.beam" => "1d39ec0aaf7001cd624eb1700f87c0945e0ad6fb4f9f9945c8b77d110726e6dd",
    "Elixir.BeamLisp.Emit.beam" => "04cf818d5cdebc03d4c63dd88be7984779b7fe21733ec0276c1beb6fe2876d2d",
    "Elixir.BeamLisp.Link.beam" => "6d554ae28992534510f9f97c2f195c72ad122c4ae54249a27b5c7254a3639464",
    "Elixir.BeamLisp.Ns.Anf.beam" => "3576b87ff4386ec58ae4380abded464c847bcff9957c0d8d849397f5d767b1c0",
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
    "Elixir.BeamLisp.Ns.Compiler.beam" => "8e3d264924b380e6ddd3f95089dda9bafae262febb2099da2174d0f47fab6ab3",
    "Elixir.BeamLisp.Ns.Core.beam" => "7d09d7d424e82fc1874b5df07268c42a54dbeb6abb582da4cc374200905456c9",
    "Elixir.BeamLisp.Ns.Diag.beam" => "f11a6d9499ccaf5446626051dfd4803ec8791ce0fe5bb4b6918ee4b40b28ef9e",
    "Elixir.BeamLisp.Ns.Init.Anf.beam" => "11d38a294bb9261173973d8febc14acf8b76821b157e144751b6e7c16616cad7",
    "Elixir.BeamLisp.Ns.Init.Compiler.beam" => "b8dad9b4bd9c8ce6f1b5cfc1423e3250fdfb1b83adfad9f1a8e9a3c420fdf6c2",
    "Elixir.BeamLisp.Ns.Init.Core.beam" => "a4acb0da65aab56c7d9279a00571c6738d141bc480e724c3749212a6904ffbfc",
    "Elixir.BeamLisp.Ns.Init.Diag.beam" => "33a5874d46925f0a89ebec891cd9ecac44a058ee8b6896ab6fa2b739bdad8a00",
    "Elixir.BeamLisp.Ns.Init.Reader.beam" => "c71406bd8e7cd39fccefb296659823e4f16657166cad877563eb89663aeffbd0",
    "Elixir.BeamLisp.Ns.Init.Rt.beam" => "d38c1c133952ed9c01636474aad5d391183e45736ae5a7cd9c7f23d8870b905d",
    "Elixir.BeamLisp.Ns.Init.Sugar.beam" => "9c432e79e91a7fd094ea447a850db6d27065df49b53757aff20e4f3a473866a9",
    "Elixir.BeamLisp.Ns.Lower.beam" => "4a1985599ded36924ba220328dedcec94fe2afaab8d5779282be70dda1752e8d",
    "Elixir.BeamLisp.Ns.Multi.beam" => "c0d746aee4827d0eab1cf6a5e1f8b73b1bb63cbe4a5b5d923f6b61ff87daa98d",
    "Elixir.BeamLisp.Ns.Reader-node.beam" => "01c68d232cbfecd67fefea27b3610c95c4ce81f2095cb096186ec191e71fc087",
    "Elixir.BeamLisp.Ns.Reader.beam" => "a176bf809326e09e2723a64ac0804a4b639691de8c08df1e55e65b54008d969e",
    "Elixir.BeamLisp.Ns.Rt.beam" => "9e30b1f6901962e25b212ec45746fbd9756c81f3d46cc61b0ed1ec287fba31b8",
    "Elixir.BeamLisp.Ns.Sugar.beam" => "cbda74e802b7ae0e7108ffbc327219c109831c4d4bcc64cc29cf198b79d66c43",
    "Elixir.BeamLisp.Tiers.beam" => "2a9f79559878bc09757dbf63b4314f5beba28313b697e202e5afc61f51e9b9a0"
  },
  "otp" => "29",
  "schema" => "beam-lisp-bootstrap-seed-v2"
}
