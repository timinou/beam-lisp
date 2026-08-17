defmodule BeamLisp.Spell.DefineToolSchemaTest do
  @moduledoc """
  The schema the model is handed MUST publish every rule the reader enforces.

  ## The defect these tests exist for

  A live turn asked the model to redefine the chat view. It produced a
  well-formed proposal and was refused:

      ✗ the definition was refused at the schema rung:
        %{message: "define: an `on` bind must either fire or write a value"}

  The refusal was correct — `spell.define/bind-form` genuinely requires one of
  `:fire` or `:value` under `:on`. The defect was that the published schema
  declared the bind sub-shapes as bare `{"type":"object"}`, with no properties
  at all. Three of the four things a bind can say (`each`, `on`, `view`) were
  documented as "some object", so the model had to guess their contents, and a
  guess was then measured against an exacting reader.

  This is the same failure as the missing system briefing, one layer down: we
  refuse a proposal for breaking a rule we never stated. A model cannot satisfy
  a contract it was not given, and a checker that enforces more than it
  publishes converts a capable model into an unlucky one.

  ## Why the tests are shaped this way

  They assert the SCHEMA against the READER's vocabulary — never the schema
  against a copy of itself. A test that restated the JSON would pass for exactly
  as long as the bug lived, which is how the two template-hole tests came to pin
  a buggy quote. The reader's list (`spell.define/proposal-keys`) is the
  independent source of truth here: it is maintained beside the `(get p :…)`
  calls it describes, so agreement between it and the schema is a real property
  and not a tautology.
  """

  use BeamLisp.SpellCase, async: true

  alias BeamLisp.Spell.Live

  setup_all do
    BeamLisp.Spell.init!(["spell.app", "spell.live"])
    :ok
  end

  defp schema, do: Live.define_tool().parameters |> JSON.decode!()

  defp props(path), do: get_in(schema(), ["properties" | path])

  describe "the bind shapes the reader demands" do
    test "an `on` bind publishes both of the actions bind-form accepts" do
      on = props(["binds", "items", "properties", "on", "properties"])

      # bind-form throws unless one of these is present. If it is not in the
      # schema, the model is being asked to guess the one thing that decides
      # whether its proposal survives.
      assert Map.has_key?(on, "fire"),
             "`on.fire` decides whether a bind is accepted and is not published"

      assert Map.has_key?(on, "value"),
             "`on.value` is the other accepted action and is not published"

      # The requirement is a disjunction, so it cannot be expressed in JSON
      # Schema's `required` — it has to be said in prose, and it has to be said.
      description = props(["binds", "items", "properties", "on"])["description"]

      assert description =~ "fire" and description =~ "value",
             "the either/or rule is enforced by the reader but stated nowhere"
    end

    test "an `each` bind publishes the fields it is read for" do
      each = props(["binds", "items", "properties", "each", "properties"])

      for field <- ~w[binding as template] do
        assert Map.has_key?(each, field), "`each.#{field}` is read but not published"
      end
    end

    test "a `view` bind publishes its binding and arms" do
      view = props(["binds", "items", "properties", "view", "properties"])

      for field <- ~w[binding arms] do
        assert Map.has_key?(view, field), "`view.#{field}` is read but not published"
      end
    end
  end

  describe "schema and reader agree" do
    test "every key the schema publishes is one the reader admits" do
      # A published key the vocabulary does not list is DROPPED at the data
      # boundary (by design — see spell.define/proposal-keys). Publishing one
      # is therefore an invitation to write a field that is silently discarded:
      # the model complies, the value vanishes, and nothing reports it.
      admitted =
        BeamLisp.Env.fetch!("spell.define", "proposal-keys")
        |> BeamLisp.Spell.Data.from_bl()
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      published = schema() |> collect_property_names() |> MapSet.new()

      unknown = MapSet.difference(published, admitted)

      assert MapSet.equal?(unknown, MapSet.new()),
             "the schema invites keys the reader drops: #{inspect(MapSet.to_list(unknown))}"
    end
  end

  # Every `properties` key anywhere in the schema, at any depth. Free-form maps
  # (`rules`, `fields`) declare no properties, so their open key sets are
  # correctly not collected — they are read positionally and stay strings.
  defp collect_property_names(%{} = node) do
    own = node |> Map.get("properties", %{}) |> Map.keys()

    nested =
      node
      |> Map.values()
      |> Enum.flat_map(fn
        %{} = child -> collect_property_names(child)
        list when is_list(list) -> Enum.flat_map(list, &collect_property_names/1)
        _ -> []
      end)

    own ++ nested
  end

  defp collect_property_names(list) when is_list(list),
    do: Enum.flat_map(list, &collect_property_names/1)

  defp collect_property_names(_), do: []
end
