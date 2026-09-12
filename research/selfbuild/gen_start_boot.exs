# W0-P5a — generate `start.script` + `start.boot` for a hand-assembled tree.
#
# Runs INSIDE the drop's VM. Reads the shipped `bl.rel` (the app list is the
# packaged truth), generates a boot script with :systools, then rewrites the
# absolute lib path to the `$RELEASE_LIB` boot variable — which is what the
# release's `bin/bl` passes as `--boot-var RELEASE_LIB <root>/lib`, and the
# reason Mix's own start.boot is ~1.5 KB larger than a naive make_script.
#
# Env: BL_PAYLOAD (drop root), BL_OUT (tree's releases/<vsn> dir)

payload = System.get_env("BL_PAYLOAD") || raise("set BL_PAYLOAD")
out = System.get_env("BL_OUT") || raise("set BL_OUT")
libdir = Path.join(payload, "lib")
relsrc = Path.join([payload, "releases", "0.1.0", "bl.rel"])

File.mkdir_p!(out)
File.cp!(relsrc, Path.join(out, "bl.rel"))

staging = Path.join(out, ".gen")
File.rm_rf!(staging)
File.mkdir_p!(staging)
File.cp!(Path.join(out, "bl.rel"), Path.join(staging, "bl.rel"))

{:ok, _mod, warns} =
  :systools.make_script(
    ~c"bl",
    [{:path, [~c"#{staging}", ~c"#{libdir}"]}, {:outdir, ~c"#{staging}"}, :silent]
  )

IO.puts("P5a make_script warnings=#{length(warns)}")

# Relocatable paths: replace the absolute lib dir with the boot variable.
text = File.read!(Path.join(staging, "bl.script"))
rewritten = String.replace(text, libdir <> "/", "$RELEASE_LIB/")
did_rewrite = rewritten != text
File.write!(Path.join(out, "start.script"), rewritten)

case :systools.script2boot(to_charlist(Path.join(out, "start")) ) do
  :ok -> :ok
  other -> IO.puts("P5a script2boot=#{inspect(other)}")
end

IO.puts("P5a rewritten=#{did_rewrite} start.script=#{File.stat!(Path.join(out, "start.script")).size} start.boot=#{File.stat!(Path.join(out, "start.boot")).size}")
IO.puts("P5a sample: #{rewritten |> String.split("\n") |> Enum.find(&String.contains?(&1, "RELEASE_LIB")) |> inspect()}")
File.rm_rf!(staging)
