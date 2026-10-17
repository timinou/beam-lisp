# convey_arity_child.exs — run in a VM whose BeamLisp.Env is compiled from the
# CURRENT priv/host/env.bl (see test/bl/convey_arity_test.bl). Prints checks.
IO.puts("env-beam=#{:code.which(BeamLisp.Env)}")
{:ok, _} = BeamLisp.Env.start_link([])
check = fn name, f ->
  v = try do f.() catch k, e -> {:raised, k, e} end
  IO.puts("check-#{name}=#{if v == true, do: "ok", else: "FAIL #{inspect(v)}"}")
  v == true
end
r = [
  check.("zero-arity-stays-zero", fn ->
    c = BeamLisp.Env.convey(fn -> :zero end)
    is_function(c, 0) and c.() == :zero
  end),
  check.("one-arity-stays-one", fn ->
    c = BeamLisp.Env.convey(fn x -> {:one, x} end)
    is_function(c, 1) and c.(7) == {:one, 7}
  end),
  check.("zero-arity-binds-the-callers-env", fn ->
    Process.put(:bl_env, :global)
    c = BeamLisp.Env.convey(fn -> BeamLisp.Env.env_id() end)
    me = self()
    spawn(fn -> send(me, {:got, c.()}) end)
    receive do {:got, v} -> v == :global after 2000 -> false end
  end)
]
IO.puts(if Enum.all?(r), do: "semantics=ok", else: "semantics=FAIL")
