seed = System.fetch_env!("BL_SEED_DIR") |> Path.expand()
nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
stage = Path.join(System.tmp_dir!(), "bl_candidate_smoke_#{nonce}")
host = Path.join([stage, "beam_lisp", "ebin"])
File.mkdir_p!(host)
original = Mix.Project.compile_path()
for path <- Path.wildcard(Path.join(original, "*")),
    File.regular?(path),
    not String.starts_with?(Path.basename(path), "Elixir.BeamLisp.Ns.") do
  File.cp!(path, Path.join(host, Path.basename(path)))
end
File.ln_s!(BeamLisp.Tiers.priv_root(), Path.join([stage, "beam_lisp", "priv"]))
Code.delete_path(original)
Code.prepend_path(host)
BeamLisp.Bootstrap.install!(host, seed_dir: seed)
{:ok, _} = Application.ensure_all_started(:beam_lisp)
BeamLisp.init()
%{op: _} = BeamLisp.Compiler.compile(BeamLisp.Reader.read_one("(+ 1 2)"), BeamLisp.Compiler.new_env("candidate-smoke"))
3 = BeamLisp.eval("(+ 1 2)")
7 = BeamLisp.eval("(do (defn candidate-smoke-f [x] {:when (pos? x)} x) (candidate-smoke-f 7))")
false = Code.ensure_loaded?(BeamLisp.Ns.Compiler2)
for ns <- ["compiler", "anf", "lower"] do
  for {_name, entries} <- BeamLisp.Env.ns_defs(ns), entry <- entries do
    %{op: :"defn-clause"} = elem(entry, 3)
  end
end
for {mod, forbidden} <- [{BeamLisp.Ns.Anf, [:normalise, :"quote-node", :"norm-pattern"]},
                         {BeamLisp.Ns.Lower, [:"eval-core", :"core-defvar-anf", :"defs->module-anf-any"]}] do
  unless Enum.all?(mod.module_info(:exports), fn {name, _} -> name not in forbidden end),
    do: raise("legacy exports remain in #{inspect(mod)}")
end
IO.inspect(BeamLisp.Generation.receipt(), label: "FRESH_CANDIDATE_RECEIPT", limit: :infinity)
IO.puts("FRESH_CANDIDATE_OK: #{seed}")
File.rm_rf!(stage)
System.halt(0)
