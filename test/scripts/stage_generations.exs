# Standalone native check: elixir test/scripts/stage_generations.exs
# It exercises the real stage without booting the language or regenerating it.
repo = Path.expand("../..", __DIR__)
root = Path.join(System.tmp_dir!(), "bl-stage-generations-#{System.unique_integer([:positive])}")
seed = Path.join(root,"seed")
dest = Path.join(root,"build")
File.mkdir_p!(seed)
File.mkdir_p!(dest)
check = fn condition, message -> if not condition, do: raise(message) end
hash = fn bytes -> Base.encode16(:crypto.hash(:sha256,bytes),case: :lower) end
current = String.duplicate("a",64)
build = String.duplicate("b",64)
old = String.duplicate("c",64)
sdk = String.duplicate("d",64)
emit = fn mod, stamp ->
  attrs = if stamp == nil, do: [], else: [{:attribute,1,:bl_compiler_key,stamp}]
  forms = [{:attribute,1,:module,mod},{:attribute,1,:export,[{:value,0}]}] ++ attrs ++
          [{:function,1,:value,0,[{:clause,1,[],[],[{:integer,1,1}]}]}]
  {:ok,^mod,bytes} = :compile.forms(forms,[:binary,:return_errors])
  name = Atom.to_string(mod) <> ".beam"
  File.write!(Path.join(dest,name),bytes)
  {name,bytes}
end
stage = fn ->
  System.cmd(Path.join(repo,"bin/bl-stage-hosts"),[Path.join(seed,"manifest.term"),seed,dest],
    stderr_to_stdout: true, env: [{"ERL_FLAGS","+S 2:2 +SDcpu 1 +SDio 1"}])
end
write_manifest = fn manifest ->
  File.write!(Path.join(seed,"manifest.term"),:io_lib.format(~c"~tp.~n",[manifest]))
end
try do
  delay = "Elixir.BeamLisp.Delay.beam"
  bytes = File.read!(Path.join(repo,"priv/bootstrap/seed/#{delay}"))
  File.write!(Path.join(seed,delay),bytes)
  {good,good_bytes} = emit.(BeamLisp.Ns.GenerationGood,current)
  {built,_} = emit.(BeamLisp.Ns.GenerationBuild,[build])
  {stale,stale_bytes} = emit.(BeamLisp.Ns.GenerationOld,[old])
  {unknown,unknown_bytes} = emit.(BeamLisp.Ns.GenerationUnknown,nil)
  {owned,owned_bytes} = emit.(BeamLisp.Ns.GenerationOwned,old)
  bad = "Elixir.BeamLisp.Ns.GenerationMalformed.beam"
  File.write!(Path.join(dest,bad),"unjudged bytes")
  manifest = %{"compiler_key"=>current,"build_key"=>build,"hosts"=>[delay],
               "modules"=>%{delay=>hash.(bytes),owned=>hash.(owned_bytes)}}
  write_manifest.(manifest)
  {output,code}=stage.()
  check.(code==0,output)
  check.(String.contains?(output,"archived 1 obsolete namespace beams"),output)
  check.(not File.exists?(Path.join(dest,stale)),"obsolete object remains on code path")
  [archived] = Path.wildcard(Path.join(dest,".stale-generations/*/#{old}/#{stale}"))
  check.(File.read!(archived)==stale_bytes,"archive did not preserve original bytes")
  for {name,want} <- [{good,good_bytes},{unknown,unknown_bytes},{owned,owned_bytes},{bad,"unjudged bytes"}] do
    check.(File.read!(Path.join(dest,name))==want,"current/owned/unjudged object changed: #{name}")
  end
  check.(File.exists?(Path.join(dest,built)),"current build-tier object was archived")
  {quiet,0}=stage.()
  check.(quiet=="","unchanged staging must be quiet: #{quiet}")
  sdk_key = hash.("sdk-declarations-v1" <> <<0>> <> current <> <<0>> <> sdk)
  {sdk_name,_}=emit.(BeamLisp.Ns.GenerationSdk,sdk_key)
  selective = Map.put(manifest,"compiler_inputs",%{"schema"=>1,"base_key"=>current,"shared"=>String.duplicate("e",64),"sdk_declarations"=>sdk})
  write_manifest.(selective)
  {quiet,0}=stage.()
  check.(quiet=="" and File.exists?(Path.join(dest,sdk_name)),"current selective SDK generation was archived")
  File.write!(Path.join(dest,stale),stale_bytes)
  File.write!(Path.join(seed,delay),"corrupt seed")
  {_,code}=stage.()
  check.(code != 0,"corrupt floor was accepted")
  check.(File.read!(Path.join(dest,stale))==stale_bytes,"corrupt floor caused namespace changes")
  IO.puts("PASS: stale-generation quarantine, exact-byte backup, current/shared/build/SDK retention, unjudged preservation, quiet reuse, verify-before-write")
after
  File.rm_rf!(root)
end
