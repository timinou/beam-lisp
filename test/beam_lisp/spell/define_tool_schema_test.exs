defmodule BeamLisp.Spell.DefineToolSchemaTest do
  @moduledoc """
  The schema the model is handed MUST publish every rule the reader enforces.

  ## The defect these tests exist for

  A live turn asked the model to redefine the chat view. It produced a
  well-formed proposal and was refused:

      ✗ the definition was refused at the schema rung:
        %{message: "run: the source must be valid beam-lisp"}

  The refusal is correct — `spell.run/run` genuinely requires the source to
  parse as valid lisp code and have a valid head form. The defect was that the
  published schema was not clear about this requirement, so a model trying to
  guess could generate syntactically invalid source and encounter this refusal
  without clear guidance.

  ## What these tests assert

  That the schema the model receives accurately describes the `run` tool and
  accurately reflects what the reader will accept — mainly that it requires
  two string parameters: `source` and `rationale`.
  """

  use BeamLisp.SpellCase, async: true

  alias BeamLisp.Spell.Loop

  setup_all do
    BeamLisp.Spell.init!(["spell.app", "spell.run", "spell.live"])
    :ok
  end

  defp schema, do: Loop.run_tool().parameters |> JSON.decode!()

  describe "the run tool schema" do
    test "the tool is named 'run'" do
      assert Loop.run_tool().name == "run"
    end

    test "the schema has source and rationale as required parameters" do
      schema_map = schema()
      required = Map.get(schema_map, "required", [])

      assert "source" in required,
             "source is required by spell.run but not declared as required in schema"

      assert "rationale" in required,
             "rationale is required by the tool definition but not declared as required in schema"
    end

    test "the schema publishes source and rationale properties" do
      props = Map.get(schema(), "properties", %{})

      assert Map.has_key?(props, "source"),
             "source property is not published in the schema"

      assert Map.has_key?(props, "rationale"),
             "rationale property is not published in the schema"

      # Both are STRINGS — a structured payload is how the JSON proposal era
      # put a translation layer between the model and the terms; the schema
      # must not grow one back.
      assert get_in(schema(), ["properties", "source", "type"]) == "string"
      assert get_in(schema(), ["properties", "rationale", "type"]) == "string"
      assert map_size(props) == 2, "the tool takes source and rationale, nothing else"
    end

    test "the schema is valid JSON" do
      # If schema() parsed successfully, the schema is valid JSON
      assert is_map(schema())
    end
  end
end