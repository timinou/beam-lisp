BeamLisp.init()
BeamLisp.Loader.ensure_loaded("compiler")

# Take a real snippet of prelude-style code, compile EACH form with the .bl
# compiler, eval it, and confirm the definitions work — the loader's job, done
# by the self-hosted compiler.
src = """
(defn sq [x] (* x x))
(defn sum-sq [xs] (reduce + 0 (map sq xs)))
(sum-sq [1 2 3 4])
"""
forms = BeamLisp.Reader.read_all(src)
env = BeamLisp.Compiler.new_env("user")

result =
  Enum.reduce(forms, nil, fn form, _acc ->
    ast = apply(BeamLisp.Ns.Compiler, :compile, [form, env])
    {val, _} = Code.eval_quoted(ast)
    val
  end)

IO.inspect(result, label: "sum-sq [1 2 3 4] via the .bl compiler backend")
IO.puts(if result == 30, do: "CK2-PREFLIGHT PASS: .bl compiler loads+runs real code", else: "FAIL")
