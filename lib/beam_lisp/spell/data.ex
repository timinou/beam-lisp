defmodule BeamLisp.Spell.Data do
  @moduledoc """
  The one conversion between Elixir data and beam-lisp values, both directions.

  Everything a model, a browser or a socket sends crosses here, and nothing
  crosses anywhere else. Before this module there were two converters in each
  direction — `to_bl/1` in `Spell.Live` and in `Spell.Server`, `bl_json/1` and
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

      {:ok, define} = BeamLisp.Env.fetch("spell.define", "define")
      define.(machine, %{kind: "view", name: "clock", …})

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

  Instead: `to_bl/2` takes the set of names the reader understands
  (`spell.define/proposal-keys`, which lives beside the `(get p :key)` calls it
  describes). A key in that set converts to the keyword it names — already
  interned, because the list is a compile-time constant of a loaded namespace.
  A key outside it stays a STRING.

  Staying a string is deliberate and is not a refusal. Two kinds of key arrive
  and only one is closed:

    * declared fields (`kind`, `templates`, `selector`) — a closed set, read as
      keywords, converted;
    * free-form map keys (CSS declarations under `rules`, push field names
      under `fields`) — an open set by definition, read POSITIONALLY by the
      emitters (`(keys m)` then print), so a string passes through untouched
      and correct.

  A hostile key is therefore neither interned nor evaluated: it becomes a
  string key in a map nobody indexes by it, and rung 1 refuses the proposal for
  the fields it is missing. Verified in `loop_test.exs` with the recorded
  payload.
  """

  alias BeamLisp.Vector

  @doc """
  Elixir data → beam-lisp values.

  `keys` says how map KEYS cross, and the three modes correspond to the three
  kinds of key this system actually has:

  | mode | for | keys become |
  |---|---|---|
  | a list of names | data a MODEL wrote, read by keyword (`spell.define`) | keyword if listed, else string |
  | `:all_strings` | data the BROWSER wrote, read by string (wire payloads, socket assigns) | string |
  | `:as_written` | data WE wrote in an Elixir literal (a provider message, a tool declaration) | unchanged |

  ```
  to_bl(%{"kind" => "view"}, ["kind"])       #=> %{kind: "view"}
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

  # A declared key becomes the keyword it names. `String.to_existing_atom/1`,
  # never `String.to_atom/1`: the guarantee is that this function CANNOT grow
  # the atom table, and `to_existing_atom` enforces it rather than intending it.
  #
  # A raise here is a bug in the VOCABULARY, not in the data, and it is
  # deliberately not rescued. It was: the rescue quietly fell back to a string,
  # and that hid a real defect for a whole wave — `:rationale` was listed but
  # never interned (nothing in `spell.define` writes it as a literal; it is
  # built by `(keyword f)` at runtime), so every proposal carrying a rationale
  # arrived with a STRING key, and rung 1 reported the field as missing while
  # naming it in the message. A correct-looking rejection of a correct
  # proposal, with no error anywhere.
  #
  # The vocabulary now spells its names as keywords, so loading the namespace
  # interns them all and this cannot fire. If it ever does, it means a name was
  # added to the list in a form that does not intern — which must be loud.
  defp convert_key(key, keys) when is_list(keys) do
    string = to_string(key)

    if string in keys do
      String.to_existing_atom(string)
    else
      string
    end
  rescue
    ArgumentError ->
      reraise ArgumentError,
              [
                message:
                  "the proposal vocabulary lists #{inspect(to_string(key))} but nothing has " <>
                    "interned it as an atom. Spell it as a keyword in " <>
                    "spell.define/proposal-keys so loading the namespace interns it — " <>
                    "otherwise the key silently stays a string and the reader sees a " <>
                    "field that is not there."
              ],
              __STACKTRACE__
  end

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

  @doc """
  The vocabulary `spell.define` reads, as strings.

  Read from the namespace itself rather than restated here. Restating it is
  exactly how the two `to_bl` regexes drifted: two statements of one fact, and
  nothing forcing them to agree. `spell.define/proposal-keys` sits beside the
  `(get p :key)` calls it describes, so a field added to the reader and not to
  the list is visible in one file.
  """
  def proposal_keys do
    case BeamLisp.Env.fetch("spell.define", "proposal-keys") do
      {:ok, keys} -> from_bl(keys)
      :error -> raise "spell.define is not loaded — no proposal vocabulary to convert against"
    end
  end
end
