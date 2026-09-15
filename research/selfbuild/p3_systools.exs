# W0-P3 — can a hand-assembled release's boot scripts come from :systools?
#
# Runs INSIDE the drop's VM. Takes the SHIPPED release's own `bl.rel` and
# regenerates `bl.script` + `bl.boot` from it with `:systools`, using only the
# payload's `lib/` as the app path. Everything except the boot scripts is held
# constant, so a pass isolates the one uncertain piece of release assembly.
#
# Env: BL_PAYLOAD = extracted drop root (default found from the running node)

payload = System.get_env("BL_PAYLOAD") || raise("set BL_PAYLOAD")
scratch = Path.join(System.get_env("BL_W0") || "/tmp/bl-w0", "p3")
libdir = Path.join(payload, "lib")
relsrc = Path.join([payload, "releases", "0.1.0", "bl.rel"])

File.rm_rf!(scratch)
File.mkdir_p!(scratch)
File.cp!(relsrc, Path.join(scratch, "bl.rel"))

IO.puts("P3  payload=#{payload}")
IO.puts("P3  rel=#{relsrc} exists=#{File.exists?(relsrc)}")
IO.puts("P3  systools=#{inspect(:code.which(:systools))}")

# systools reads Name.rel from the code path (or `path`) and writes Name.script
# to `outdir`.
opts = [{:path, [~c"#{scratch}", ~c"#{libdir}"]}, {:outdir, ~c"#{scratch}"}, :silent]

result =
  try do
    :systools.make_script(~c"bl", opts)
  rescue
    e -> {:raised, Exception.format(:error, e, __STACKTRACE__)}
  end

case result do
  {:ok, _mod, warns} ->
    IO.puts("P3  make_script ok warnings=#{length(warns)}")
    for w <- Enum.take(warns, 5), do: IO.puts("P3    warn #{inspect(w)}")

  {:error, _mod, errs} ->
    IO.puts("P3  make_script ERROR n=#{length(errs)}")
    for e <- Enum.take(errs, 8), do: IO.puts("P3    err #{inspect(e)}")

  other ->
    IO.puts("P3  make_script other=#{inspect(other)}")
end

script = Path.join(scratch, "bl.script")
IO.puts("P3  script=#{script} exists=#{File.exists?(script)} bytes=#{if File.exists?(script), do: File.stat!(script).size, else: 0}")
IO.puts("P3  after make_script dir=#{inspect(File.ls!(scratch))}")

# OTP appends ".script": pass the stem, not the filename.
boot_result =
  if File.exists?(script) do
    try do
      :systools.script2boot(Path.rootname(script) |> to_charlist())
    rescue
      e -> {:raised, Exception.format(:error, e, __STACKTRACE__)}
    end
  else
    :skipped
  end

boot = Path.join(scratch, "bl.boot")
IO.puts("P3  script2boot=#{inspect(boot_result)} boot_exists=#{File.exists?(boot)} boot_bytes=#{if File.exists?(boot), do: File.stat!(boot).size, else: 0}")

# Compare against the shipped boot script, if both exist.
shipped = Path.join([payload, "releases", "0.1.0", "start.boot"])
if File.exists?(boot) and File.exists?(shipped) do
  a = File.read!(boot)
  b = File.read!(shipped)
  IO.puts("P3  shipped start.boot bytes=#{byte_size(b)} identical=#{a == b}")
end
