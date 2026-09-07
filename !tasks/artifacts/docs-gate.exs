BeamLisp.Loader.ensure_loaded("bl.doc")
runner = BeamLisp.Env.fetch!("bl.doc", "run-and-write!")
paths = ["docs/memory-policy/shared-lazy-values.bl.md", "docs/compiler/finite-data.bl.org", "docs/compiler/generation.bl.org",
         "docs/from-source-to-silicon/03-one-ir.bl.org",
         "docs/dev/executable-changes.bl.org", "examples/dev/change-session.bl.org"]
for path <- paths do
  result = BeamLisp.RT.invoke(runner, [path])
  IO.inspect(result, label: "DOC_RESULT", limit: :infinity)
  unless BeamLisp.LazySeq.to_list(Map.fetch!(result, :errors)) == [], do: raise("document failed: #{path}")
end
for path <- ["docs/dev/executable-changes.bl.org", "examples/dev/change-session.bl.org"] do
  before = File.read!(path)
  result = BeamLisp.RT.invoke(runner, [path])
  unless BeamLisp.LazySeq.to_list(Map.fetch!(result, :errors)) == [], do: raise("replay failed: #{path}")
  unless File.read!(path) == before, do: raise("non-idempotent document replay: #{path}")
  IO.puts("DOC_REPLAY_IDENTICAL: #{path}")
end
Enum.each(Process.get(:canonical_upgrade_cleanup, []), &File.rm_rf!/1)
System.halt(0)
