defmodule BeamLisp.Spell.Data do
  @moduledoc """
  The one conversion between Elixir data and beam-lisp values, both directions.

  Everything a model, a browser or a socket sends crosses here, and nothing
  crosses anywhere else. Before this module there were two converters in each
  direction — `to_bl/1` in `Spell.Loop` (then `Spell.Live`) and in `Spell.Server`, `bl_json/1` and
  `plain/1` — and the two `to_bl`s had already diverged: one admitted
  `[a-z][a-z0-9_-]*`, the other `[a-zA-Z][a-zA-Z0-9_-]*`. Two copies of a
  security boundary that disagree are one boundary and one hole.

  ## Why this is a converter and no longer a printer

  Both `to_bl`s printed beam-lisp SOURCE, which was then handed to
  `Compiler.eval_string/1`. That is what made a map KEY dangerous: a key could
  close the call and open a new form, so

      "kind \\"view\\"}))\\n(def pwned 99)\\n(def z {:kind"

  evaluated three top-level forms, the middle one arbitrary, before any
  validation ran. Reproduced, fixed by whitelisting keys, and recorded in
  commit e6a4828.

  Whitelisting the key made THAT payload safe. It did not make printing safe —
  it made one class of payload safe, which is the shape of every escaping bug
  ever written. The real defect was printing at all.

  A beam-lisp `defn` is an ordinary Elixir function value:

      {:ok, run} = BeamLisp.Env.fetch("spell.run", "run")
      run.(machine, "(defview clock …)")

  So there is nothing to print, nothing to parse, and no source for a key to
  break out of. What is left is a data conversion, and a data conversion cannot
  be escaped out of.

  ## The measurement that forced it

  Measured 2026-08-16, OTP 29, seed contract, 200 iterations:

      direct fn value      118 µs/call    0 modules   0 atoms per 100 events
      eval_string        8 176 µs/call  201 modules 204 atoms per 100 events

  `eval_string` compiles a fresh module per call. `Spell.Server.info/3` ran it
  once per STREAMED TOKEN, so a 500-token answer left ~1000 modules behind. The
  atom table is never collected and its exhaustion aborts the VM uncatchably
  (`BeamLisp.AtomGuard`), so this was not a performance note — it was an
  unbounded leak on the path a user drives with their keyboard.

  ## How keys are decided

  Not by a regex. A regex answers "does this look like a name?", which is the
  same question escaping asks, and it still ends in `String.to_atom/1` — making
  the atom table writable by whoever is talking to the model.

  So there is no third mode: `:all_strings` keeps browser keys as strings, and
  `:as_written` keeps OUR literal keys untouched. Nothing that crosses here
  interns anything.

  Model-written definitions never cross as maps at all anymore: the `run`
  tool's payload is SOURCE TEXT, a plain string value, read (never evaluated)
  by `spell.run`. The only maps that cross are ours and the browser's.
  """

  alias BeamLisp.Vector

  @doc """
  Elixir data → beam-lisp values.

  `keys` says how map KEYS cross, and the two modes correspond to the two
  kinds of key this system actually has:

  | mode | for | keys become |
  |---|---|---|
  | `:all_strings` | data the BROWSER wrote, read by string (wire payloads, socket assigns) | string |
  | `:as_written` | data WE wrote in an Elixir literal, keys fixed in this repository's source | unchanged |

  (There used to be a third mode — a keyword vocabulary for data a MODEL
  wrote, from the JSON-proposal era. The tool now carries source TEXT, which
  crosses as a plain string value, so the vocabulary and its
  `to_existing_atom` dance have no caller left.)

  ```
  to_bl(%{"kind" => "view"}, :all_strings)   #=> %{"kind" => "view"}
  to_bl(%{role: "user"}, :as_written)        #=> %{role: "user"}
  ```

  `:as_written` is safe for exactly the reason the other two are not trusted:
  its keys are literals in this repository's source, fixed before any model or
  browser speaks. It interns nothing because there is nothing to intern — the
  atoms already exist. Reaching for it with wire data would defeat the whole
  boundary, which is why the mode is named after its precondition rather than
  after its behaviour.

  Lists become `BeamLisp.Vector`s, because that is what beam-lisp's `mapv`,
  `count` and destructuring expect; an Elixir list reads as a beam-lisp LIST,
  which is a different type with different behaviour in `get`/`nth`.
  """
  def to_bl(value, keys)

  def to_bl(%Vector{} = v, keys), do: v |> Vector.to_list() |> to_bl(keys)

  def to_bl(%_{} = struct, _keys) do
    # A struct is never valid here and the failure must be loud. `Date`,
    # `DateTime` and friends would otherwise convert to a map of their internal
    # fields and reach an emitter as a plausible-looking record.
    raise ArgumentError,
          "cannot convert the struct #{inspect(struct.__struct__)} to a beam-lisp value — " <>
            "only JSON-shaped data crosses this boundary"
  end

  # Ordering the clauses this way rather than guarding with `is_bl_map/1` is
  # deliberate: a struct must produce a LOUD error naming the type, not fall
  # through to a clause that quietly declines it.
  #
  # is_map-ok: the `%_{}` clause immediately above rejects EVERY struct by name
  # before this one is reached, so "any map" here means a plain map.
  def to_bl(map, keys) when is_map(map) do
    Map.new(map, fn {k, v} -> {convert_key(k, keys), to_bl(v, keys)} end)
  end

  def to_bl(list, keys) when is_list(list), do: Vector.new(Enum.map(list, &to_bl(&1, keys)))
  def to_bl(other, _keys), do: other

  defp convert_key(key, :all_strings), do: to_string(key)
  defp convert_key(key, :as_written), do: key

  @doc """
  beam-lisp values → plain Elixir data that survives `JSON.encode!/1`.

  Vectors become lists, keywords become strings, maps are rebuilt with string
  keys. Everything crossing back into a socket assign or `report.json` goes
  through here, because the bridge pushes assigns to the browser verbatim and a
  keyword or a `%Vector{}` is not JSON.

  `true`, `false` and `nil` stay themselves: they are JSON values, and turning
  them into `"true"` would make a boolean assign render as a non-empty string —
  which is truthy in the browser even when it says `"false"`.
  """
  def from_bl(%Vector{} = v), do: v |> Vector.to_list() |> Enum.map(&from_bl/1)
  def from_bl(list) when is_list(list), do: Enum.map(list, &from_bl/1)

  def from_bl(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom),
    do: Atom.to_string(atom)

  # is_map-ok: the Vector clause above takes the one beam-lisp struct that
  # reaches here; any other struct is a bug in the caller, and `not is_struct`
  # makes that a FunctionClauseError at the boundary rather than a map of
  # internal fields silently encoded into a report.
  def from_bl(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(from_bl(k)), from_bl(v)} end)

  def from_bl(other), do: other
end
