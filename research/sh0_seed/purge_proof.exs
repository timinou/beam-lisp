# P0 definitive proof: the AOT'd .bl nano-compiler runs with beam-lisp's OWN
# compiler modules PURGED from the VM. If it still turns (+ 1 2) into 3, then
# nothing about beam-lisp's Elixir-written compiler is in the runtime loop —
# only the AOT'd .beam + Elixir/Erlang stdlib.
BeamLisp.init()

# The form (+ 1 2) as reader-shaped data: a list whose head is the symbol +.
form = [{:symbol, "+"}, 1, 2]

before = apply(BeamLisp.Ns.Bootstrap.Nano, :run, [form])
IO.puts("with compiler present:  (+ 1 2) => #{inspect(before)}")

# Now remove beam-lisp's compiler and reader from the running VM entirely.
for m <- [BeamLisp.Compiler, BeamLisp.Reader] do
  :code.purge(m)
  :code.delete(m)
  :code.purge(m)
end
loaded_after = Enum.filter([BeamLisp.Compiler, BeamLisp.Reader], &:code.is_loaded/1)
IO.puts("compiler/reader loaded after purge: #{inspect(loaded_after)}")

after_val = apply(BeamLisp.Ns.Bootstrap.Nano, :run, [form])
IO.puts("with compiler PURGED:   (+ 1 2) => #{inspect(after_val)}")

IO.puts(if after_val == 3 and loaded_after == [], do: "P0 PASS", else: "P0 FAIL")
