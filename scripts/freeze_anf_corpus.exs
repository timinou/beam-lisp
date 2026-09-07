# Freeze the committed canonical seed into an explicit NEW output directory.
# ANF_CORPUS_OUTPUT=/tmp/corpus mix run --no-compile --no-start scripts/freeze_anf_corpus.exs
# Never overwrite the immutable corpus used to verify a compiler migration.
output = System.fetch_env!("ANF_CORPUS_OUTPUT") |> Path.expand()
File.mkdir_p!(output)
nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
stage = Path.join(System.tmp_dir!(), "bl_seed_corpus_#{nonce}")
File.mkdir!(stage)
Code.prepend_path(stage)
BeamLisp.Bootstrap.install!(stage)
{:ok, _} = Application.ensure_all_started(:beam_lisp)
BeamLisp.init()
seed_hash = :crypto.hash(:sha256, File.read!(Path.join(BeamLisp.Bootstrap.seed_dir(), "manifest.exs")))
for path <- ~w(priv/boot/core.bl priv/boot/sugar.bl priv/boot/compiler.bl priv/boot/reader.bl priv/std/multi.bl priv/std/optics.bl) do
  child = BeamLisp.Env.fork()
  try do
    BeamLisp.Env.with_env(child, fn ->
      source = File.read!(path)
      forms = BeamLisp.Reader.read_all(source) |> Enum.to_list()
      env = BeamLisp.Compiler.new_env("anfcensus")
      entries = Enum.map(forms, fn form ->
        BeamLisp.Compiler.reset_fresh!()
        %{op: _} = node = BeamLisp.Compiler.compile(form, env)
        {form, {:ok, node}}
      end)
      payload = %{version: 2, source: path, entries: entries,
        source_sha256: :crypto.hash(:sha256, source), seed_manifest_sha256: seed_hash}
      target = Path.join(output, String.replace(path, "/", "_") <> ".etf")
      File.write!(target, :erlang.term_to_binary(payload, [:compressed]), [:exclusive])
      IO.puts("#{path}: #{length(entries)} canonical seed forms frozen")
    end)
  after
    BeamLisp.Env.destroy(child)
  end
end
File.rm_rf!(stage)
System.halt(0)
