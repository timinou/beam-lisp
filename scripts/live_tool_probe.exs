# Sends a real tools-enabled request and decodes it with extract-turn.
".env" |> File.read!() |> String.split("\n") |> Enum.each(fn l ->
  case String.split(String.trim(l), "=", parts: 2) do
    [k, v] -> if not String.starts_with?(k, "#") and k != "", do: System.put_env(k, v)
    _ -> :ok
  end
end)

:inets.start(); :ssl.start()
BeamLisp.Spell.init!()

bl = &BeamLisp.Compiler.eval_string/1

src = ~S"""
(let [cfg (assoc (spell.provider/from-env) :tools
            [{:name "define"
              :description "Add a contract or a view to the running machine."
              :parameters "{\"type\":\"object\",\"properties\":{\"kind\":{\"type\":\"string\",\"enum\":[\"contract\",\"view\"]},\"name\":{\"type\":\"string\"},\"rationale\":{\"type\":\"string\"}},\"required\":[\"kind\",\"name\",\"rationale\"]}"}])
      msgs [{:role "user" :content "Use the define tool to add a view named clock. Call the tool, do not describe it."}]]
  (spell.provider/ask-turn cfg msgs))
"""

IO.inspect(bl.(src), label: "live turn", limit: :infinity)
