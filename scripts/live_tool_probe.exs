# Sends a real tools-enabled request and decodes it with extract-turn.
# Credentials: environment, then `.env`, then the agent db — see
# `BeamLisp.Spell.Credentials`.
BeamLisp.Spell.Credentials.load()

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
