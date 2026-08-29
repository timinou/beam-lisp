defmodule BeamLisp.Record do
  @moduledoc """
  beam-lisp's `defrecord` and `deftype` types.

  **Why a real Elixir struct.** A `defrecord` is a map with a known key
  set plus a type identity — which is exactly what an Elixir struct is.
  Backing records with `defstruct` modules means `IO.inspect`, Elixir
  pattern matching and `Map` functions all work on records for free, and
  equality (`Kernel.==`) falls out as Clojure-correct without any code:
  two records of the same type with equal fields compare equal, a record
  and a plain map with the same entries do not, and two records of
  different types never do. That is the whole record equality rule, and
  it is free because structs carry their module in `__struct__`.

  `deftype` is deliberately NOT a struct: Clojure's deftype has no map
  semantics — no keyword lookup, no `seq`, no `assoc` — so a beam-lisp
  deftype instance is a bare tagged tuple `{:bl-deftype, module, fields}`
  (see `build_type/2`). Being a tuple, it can never be swallowed by an
  `is_bl_map` clause and its field surface is reachable only through
  `deftype_field/2` (the `.-field` / `.field` reader forms). The type
  identity still lives in a module atom so protocols can dispatch on it.

  **The struct-is-a-map hazard, doubled.** A record struct satisfies
  `is_map`, so every `when is_bl_map(...)` clause in `BeamLisp.RT` matches
  one. Records are different from the other structs (Vector/LazySeq/Set)
  in that they are *supposed* to behave as maps — but the `__struct__`
  key is internal and must never leak into `seq`/`keys`/`count`. The RT
  routes records through `%{__struct__: mod}` clauses that precede the
  plain `is_bl_map` clauses and read fields via this module's registry, so
  iteration sees the declared fields (plus any assoc'd extras) and never
  the struct's hidden key. `seqable` in RT gets the same treatment so
  `map`/`filter` compose records correctly (a struct implements no
  `Enumerable`, so `Enum.map` on one raises rather than silently
  iterating `__struct__`).

  **Registry.** Records and deftypes are created lazily at runtime (when
  their `defrecord`/`deftype` form evaluates), so no pattern match can
  name them. Their modules are registered here in a `:persistent_term`
  map — module atom → `{kind, ns, name, fields}` — so RT can ask "is this
  a record, and what are its fields" without an ETS owner. Writes are
  rare (one per definition) and reads are O(1); `persistent_term` has no
  holder process to outlive.
  """

  alias BeamLisp.Env
  import BeamLisp.Guards, only: [is_bl_map: 1]

  @registry_key {__MODULE__, :registry}

  # --- type predicates -------------------------------------------------

  @doc "True for a record instance (a registered record struct)."
  def record?(%{__struct__: mod}) when is_atom(mod), do: record_module?(mod)
  def record?(_), do: false

  @doc "True for a record's module atom."
  def record_module?(mod) when is_atom(mod), do: match?({:record, _, _, _}, info(mod))
  def record_module?(_), do: false

  @doc "True for a deftype's module atom."
  def deftype_module?(mod) when is_atom(mod), do: match?({:deftype, _, _, _}, info(mod))
  def deftype_module?(_), do: false

  @doc "The registry entry `{kind, ns, name, fields}` for `mod`, or nil."
  def info(mod) when is_atom(mod) do
    case :persistent_term.get(@registry_key, %{}) do
      %{^mod => entry} -> entry
      _ -> nil
    end
  end

  def info(_), do: nil

  @doc "The declared field names (atoms, in definition order) of a record/deftype."
  def fields_of(mod) do
    case info(mod) do
      {_, _, _, fields} -> fields
      nil -> raise ArgumentError, "not a beam-lisp record/deftype: #{inspect(mod)}"
    end
  end

  # --- definition ------------------------------------------------------

  @doc """
  Define a record type `name` in namespace `ns` with `fields`, returning
  the struct module. The module is created (or, on redefinition, updated)
  with a `defstruct` so it is a first-class Elixir struct; the registry
  records the field list.
  """
  def define(ns, name, fields) do
    # The whole define is a VM-wide critical section: two envs loading
    # the same namespace concurrently would otherwise race Module.create
    # ("currently being defined" CompileError) — the record registry is
    # deliberately global (PLAN-046), so its creation must serialize.
    mod = module_name(ns, name)
    # {resource, requester}: :global lock ids must be that 2-tuple shape.
    :global.trans({mod, self()}, fn ->
      field_atoms = Enum.map(fields, &String.to_atom/1)
      struct_fields = Enum.map(field_atoms, &{&1, nil})
      create_module(mod, quote do: defstruct(unquote(struct_fields)))
      register(mod, :record, ns, name, field_atoms)
      mod
    end)
  end

  @doc """
  Define a deftype `name` in `ns` with `fields`, returning its module.
  No `defstruct`: a deftype has no map semantics. The module exists only
  as a type identity for protocol dispatch.
  """
  def define_type(ns, name, fields) do
    # Serialized for the same reason as define/3.
    mod = module_name(ns, name)

    :global.trans({mod, self()}, fn ->
      create_module(mod, quote do: :ok)
      register(mod, :deftype, ns, name, Enum.map(fields, &String.to_atom/1))
      mod
    end)
  end

  # --- construction ----------------------------------------------------

  @doc """
  The positional constructor `->Name`: a variadic (min-0) fn so the
  handler receives the whole argument list at once. Arity is checked
  against the field count; a record builds a struct, a deftype a tagged
  tuple.
  """
  def positional_ctor(mod) do
    case info(mod) do
      {kind, _ns, name, fields} ->
        n = length(fields)

        {:"$blfn", %{}, {0, fn args ->
          if length(args) == n do
            case kind do
              :record -> struct_map(mod, Enum.zip(fields, args))
              :deftype -> {:bl_deftype, mod, List.to_tuple(args)}
            end
          else
            raise ArgumentError,
                  "wrong number of args (#{length(args)}) for #{name} constructor, expected #{n}"
          end
        end}}

      nil ->
        raise ArgumentError, "not a beam-lisp record/deftype: #{inspect(mod)}"
    end
  end

  @doc "The `map->Name` constructor: a record built from a map's known fields."
  def map_ctor(mod), do: fn m -> map_construct(mod, m) end

  @doc "Build a record struct from `{field, value}` pairs (fields not given default to nil)."
  def struct_map(mod, kv), do: Map.put(Map.new(kv), :__struct__, mod)

  @doc "Build a record from a map, taking only its declared fields."
  # A record is built from a *plain* map's declared fields — a struct source
  # would leak its internal `__struct__` into the new record.
  def map_construct(mod, m) when is_bl_map(m) do
    fields = fields_of(mod)
    Map.merge(Map.new(fields, &{&1, nil}), Map.take(m, fields)) |> Map.put(:__struct__, mod)
  end

  @doc """
  Build a record from a positional argument list (used by `construct_list`
  callers and the `->Name` body).
  """
  def construct_list(mod, values) when is_list(values) do
    fields = fields_of(mod)
    unless length(values) == length(fields) do
      raise ArgumentError,
            "wrong number of values (#{length(values)}) for record #{inspect(mod)}, expected #{length(fields)}"
    end
    struct_map(mod, Enum.zip(fields, values))
  end

  @doc """
  Resolve a `#Name{...}` (or `#ns/Name{...}`) record literal read by the
  reader against `ns` and construct the record from the given map.
  """
  def literal(ns, name, fields_map) do
    case Env.fetch(ns, name) do
      {:ok, mod} when is_atom(mod) ->
        if record_module?(mod) do
          map_construct(mod, fields_map)
        else
          raise "record literal #{name} does not name a record"
        end

      _ ->
        raise "record literal #{name}: no such record in namespace #{ns}"
    end
  end

  # --- deftype field access -------------------------------------------

  @doc "Build a deftype instance from its positional field values."
  def build_type(mod, values) when is_list(values) do
    {:bl_deftype, mod, List.to_tuple(values)}
  end

  @doc """
  Read a deftype field by name: `(.-x obj)` and `(.x obj)`. Records do
  not support field access (they use keyword lookup); only a deftype
  tuple reaches here.
  """
  def deftype_field({:bl_deftype, mod, tuple}, field) do
    fields = fields_of(mod)

    case Enum.find_index(fields, &(&1 == field)) do
      nil -> raise ArgumentError, "no field #{inspect(field)} on #{inspect(mod)}"
      i -> elem(tuple, i)
    end
  end

  def deftype_field(other, _field),
    do: raise(ArgumentError, "field access on a non-deftype: #{inspect(other)}")

  # --- internals -------------------------------------------------------

  # `defrecord`/`deftype` run in a namespace; the struct module is scoped
  # by it so two namespaces may each define their own `Point` without
  # colliding. Namespace dots nest, so `geometry` → BeamLisp.Record.Geometry.Point.
  defp module_name(ns, name) do
    segments = ns |> String.split(".") |> Enum.map(&Macro.camelize/1)
    Module.concat([BeamLisp.Record | segments] ++ [name])
  end

  # Rebuilding a struct module on every defrecord evaluation is the
  # normal case (hot reload), so the module-conflict warning is noise.
  defp create_module(mod, block) do
    prev = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)

    try do
      Module.create(mod, block, Macro.Env.location(__ENV__))
    after
      Code.compiler_options(prev)
    end
  end

  defp register(mod, kind, ns, name, fields) do
    :persistent_term.put(
      @registry_key,
      Map.put(:persistent_term.get(@registry_key, %{}), mod, {kind, ns, name, fields})
    )
  end
end
