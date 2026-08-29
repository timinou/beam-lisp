defmodule BeamLisp.RT do
  @moduledoc """
  Runtime primitives seeded into the `core` namespace before any
  beam-lisp code runs. Everything here is an ordinary Elixir function
  value, so compiled beam-lisp code calls them with plain `apply/2`.
  """

  alias BeamLisp.{Env, LazySeq, Set, Sorted}
  alias BeamLisp.Sorted.{SortedMap, SortedSet}

  # `rem` is seeded as a core prim (Clojure's remainder), so the module
  # must not inherit Kernel.rem/2 — the local def below is the source of
  # truth and every `rem` here (even?/odd?) resolves to it.
  import BeamLisp.Guards, only: [is_bl_map: 1, is_ref_type: 1, is_data_tuple: 1]
  import Kernel, except: [rem: 2]

  @multi_fn_tag :"$blfn"

  @doc "Wraps arity-dispatched clauses; Elixir fns are fixed-arity, so multi-arity and variadic beam-lisp fns need a tag."
  # is_map-ok: clauses/fixed are internal arity→fn maps built by this
  # module — never user values, so struct-vs-map never applies.
  def multi_fn(clauses) when is_map(clauses), do: {@multi_fn_tag, clauses, nil}
  def multi_fn(clauses, {min, f}) when is_map(clauses), do: {@multi_fn_tag, clauses, {min, f}}

  @doc false
  # is_map-ok: fixed is the internal arity→fn map from the tag tuple above.
  def invoke({@multi_fn_tag, fixed, variadic}, args) when is_map(fixed) do
    arity = length(args)

    case fixed do
      %{^arity => f} ->
        apply(f, args)

      _ ->
        case variadic do
          nil ->
            raise "wrong number of args (#{arity})"

          {min, f} when arity >= min ->
            apply(f, Enum.take(args, min) ++ [Enum.drop(args, min)])

          {min, _f} ->
            raise "wrong number of args (#{arity}, expected at least #{min})"
        end
    end
  end

  @doc false
  def invoke({:"$remote", module, fun}, args) do
    # Dynamic invocation of a host-module handle: the runtime half of the
    # capability gate (static remote calls are rejected at compile time).
    if BeamLisp.Env.caps_allowed?(module, BeamLisp.Env.op_of(module, fun)) do
      apply(module, fun, args)
    else
      raise BeamLisp.CompileError,
        message:
          "module #{inspect(module)} is not granted in this environment " <>
            "(dynamic invocation of #{inspect(module)}.#{fun}/#{length(args)} denied)"
    end
  end

  @doc false
  def invoke(f, args) when is_function(f), do: apply(f, args)

  @doc "Keywords are functions of maps, as in jank and Clojure: `(:a m)` ≡ `(get m :a)`."
  def invoke(kw, [m]) when is_atom(kw), do: get(m, kw)
  def invoke(kw, [m, default]) when is_atom(kw), do: get(m, kw, default)

  # Vectors are functions of their indices: `([a b] 1)` ≡ `(nth [a b] 1)`,
  # which is how jank's doseq indexes its binding vector.
  def invoke(%BeamLisp.Vector{} = v, [i]) when is_integer(i), do: BeamLisp.Vector.nth(v, i)

  @doc """
  `~@` splicing. Clojure splices any seqable onto the rest of the form,
  so a spliced vector or lazy seq must flatten like a list — jank's
  macros splice binding vectors.
  """
  def splice(spliced, tail), do: to_list(spliced) ++ tail

  defp to_list(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp to_list(nil), do: []
  defp to_list(xs) when is_list(xs), do: xs
  defp to_list(other), do: Enum.to_list(other)

  @doc """
  A first-class handle to a remote function, e.g. `(map String/upcase xs)`.

  Refuses a module that does not exist. A lowercase qualified name is
  read as Erlang interop, so a mistyped or unaliased prefix — `i/NONE`
  when nothing aliases `i` — would otherwise produce a perfectly usable
  handle to a module that was never loaded. That value compares unequal
  to everything and fails only much later, at the call site, blaming a
  module the author never mentioned. Failing here names the real
  mistake while the reference is still in view.
  """
  def remote_fun(module, fun) do
    # Creating a host-module handle is itself interop: gate it, so a
    # capped env cannot even FORGE a handle it would later sneak past a
    # caller that forgot to check (the $remote invoke clause checks too —
    # belt and suspenders, since handles travel between processes).
    unless BeamLisp.Env.caps_allowed?(module, BeamLisp.Env.op_of(module, fun)) do
      raise BeamLisp.CompileError,
        message: "module #{inspect(module)} is not granted in this environment"
    end

    if Code.ensure_loaded?(module) do
      {:"$remote", module, fun}
    else
      raise BeamLisp.CompileError,
        message:
          "unresolved qualified name #{module}/#{fun}: no namespace or alias named " <>
            "#{inspect(module)} is in scope, and no such module is loadable. A lowercase " <>
            "prefix means Erlang interop — if you meant a beam-lisp namespace, require or " <>
            "alias it first."
    end
  end

  @doc """
  A value normalized for use as a HASH KEY.

  Metadata is invisible to `=` (Clojure's contract, and what `eqv/2`
  implements for vectors), so it must be invisible to hashing too \u2014
  otherwise `(= a b)` is true while `(get {a :x} b)` is nil, and the
  same value counts twice under `distinct` or in a set. Elixir maps and
  MapSets key on the raw term, which DOES see the struct field, so the
  metadata is stripped here at every hash boundary.

  Nested collections are normalized recursively: a vector holding a
  metadata-bearing vector must hash like the plain one.
  """
  def hash_key(%BeamLisp.Vector{items: items, meta: m} = v) do
    normalized = if m == nil, do: v, else: %BeamLisp.Vector{v | meta: nil}

    case items do
      t when is_tuple(t) and not (tuple_size(t) == 5 and elem(t, 0) == :bl_vec) ->
        # Rebuild only when something inside actually carries metadata.
        # `hash_key` runs on EVERY map/set key operation, so the
        # overwhelmingly common case — no metadata anywhere — must not
        # allocate a new vector per lookup.
        if needs_normalizing?(t) do
          %BeamLisp.Vector{
            normalized
            | items: t |> Tuple.to_list() |> Enum.map(&hash_key/1) |> List.to_tuple()
          }
        else
          normalized
        end

      _ ->
        normalized
    end
  end

  def hash_key(%Set{members: members} = s) do
    if Enum.any?(members, &carries_meta?/1),
      do: %Set{members: MapSet.new(Enum.map(members, &hash_key/1))},
      else: s
  end

  def hash_key(xs) when is_list(xs) do
    if Enum.any?(xs, &carries_meta?/1), do: Enum.map(xs, &hash_key/1), else: xs
  end

  # is_map-ok: normalizing a plain map's keys and values for hashing.
  def hash_key(m) when is_bl_map(m) do
    if Enum.any?(m, fn {k, v} -> carries_meta?(k) or carries_meta?(v) end),
      do: Map.new(m, fn {k, v} -> {hash_key(k), hash_key(v)} end),
      else: m
  end

  def hash_key(other), do: other

  defp needs_normalizing?(t) when is_tuple(t) do
    Enum.any?(Tuple.to_list(t), &carries_meta?/1)
  end

  # Whether `x` holds metadata anywhere inside it. Cheap for the common
  # case (a scalar answers immediately) and short-circuits on the first
  # hit, so a deep structure is only walked as far as its first metadata.
  defp carries_meta?(%BeamLisp.Vector{meta: m}) when m != nil, do: true

  defp carries_meta?(%BeamLisp.Vector{items: items}) do
    case items do
      t when is_tuple(t) and not (tuple_size(t) == 5 and elem(t, 0) == :bl_vec) ->
        needs_normalizing?(t)

      _ ->
        false
    end
  end

  defp carries_meta?(%Set{members: members}), do: Enum.any?(members, &carries_meta?/1)
  defp carries_meta?(xs) when is_list(xs), do: Enum.any?(xs, &carries_meta?/1)

  # is_map-ok: scanning a plain map for nested metadata.
  defp carries_meta?(m) when is_bl_map(m),
    do: Enum.any?(m, fn {k, v} -> carries_meta?(k) or carries_meta?(v) end)

  defp carries_meta?(_), do: false

  def get(m, key, default \\ nil)
  # A vector is a struct, so it is also a map — index access must be
  # matched before the map clause or `(get [a b] 1)` silently yields
  # the default.
  def get(%BeamLisp.Vector{} = v, i, _default), do: BeamLisp.Vector.nth(v, i)
  # A transient map is a wrapper (not a struct); read through to its
  # live state. frequencies/group-by both do `(get transient k d)`.
  def get({:"$transient", :map, key}, k, default),
    do: BeamLisp.Transient.get({:"$transient", :map, key}, k, default)

  # A set is a function of its members: `(get #{:a :b} :a)` is `:a`,
  # and `(get s x)` is `x` iff `x` is a member (default otherwise).
  def get(%Set{} = s, x, default),
    do: if(Set.member?(s, x), do: x, else: default)

  # Ordered collections mirror their hashed siblings: a sorted map looks
  # up by key, a sorted set is a function of its members. Both are structs,
  # so these MUST precede the is_bl_map clause.
  def get(%SortedMap{} = m, k, default), do: Sorted.map_get(m, k, default)

  def get(%SortedSet{} = s, x, default),
    do: if(Sorted.set_member?(s, x), do: x, else: default)

  # A record is a struct (and so a map), but its `__struct__` key is
  # internal — field access goes through the public fields only, so
  # `(:__struct__ p)` is nil, not the module.
  # A reference (atom/volatile/future/promise/reduced) is not a map — a
  # struct-is-a-map would read its internals or return nil on a miss.
  def get(%{__struct__: mod} = m, _key, _default) when is_atom(mod) and is_ref_type(m),
    do: raise(ArgumentError, "get: #{inspect(mod)} is a reference, not a collection")

  def get(%{__struct__: mod} = m, key, default) when is_atom(mod) do
    if BeamLisp.Record.record?(m) do
      if key == :__struct__, do: default, else: Map.get(m, key, default)
    else
      Map.get(m, key, default)
    end
  end

  def get(m, key, default) when is_bl_map(m), do: Map.get(m, hash_key(key), default)
  def get(nil, _key, default), do: default

  @doc """
  Clojure `identical?`: reference equality.

  On the BEAM this can only be `===` (the no-coercion strict compare),
  and that is the honest thing to ship, with one documented deviation:

  * terms that genuinely carry reference identity on the VM — funs,
    pids, ports, references — compare **by identity**: `===` is true
    exactly for the same term. That matches Clojure exactly.
  * every immutable, value-typed term (numbers, atoms, strings, tuples,
    maps, lists, vectors) has **no** reference identity on the BEAM —
    two equal terms are indistinguishable and may or may not share
    memory. `===` gives structural equality for these: equal is `true`
    where Clojure's `identical?` would be `false` (Clojure only
    *guarantees* a result for references). This is the closest true
    predicate the VM admits; pretending to a reference identity the
    term model does not have would be a lie.

  Specter's `NONE` sentinel is built on this: two copies of the sentinel
  must not be "the same", and two copies of any other value may be. `===`
  delivers exactly that for the sentinel's reference-typed or atom
  representation (atoms are interned, so a sentinel atom is genuinely
  one value, like a Clojure keyword sentinel).
  """
  def identical?(a, b), do: a === b

  @doc "Clojure `not`: truthiness-based — true exactly for `nil` and `false`."
  def not_(x), do: x == false or x == nil

  def first(nil), do: nil
  def first([]), do: nil
  def first([h | _]), do: h
  def first(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.first(v)

  def first(%LazySeq{} = l) do
    case LazySeq.cell(l) do
      nil -> nil
      [h | _] -> h
    end
  end

  # A map is a seq of [k v] entry vectors (Clojure MapEntry); first/rest/
  # seq/next just delegate to the entry list — what lets reduce, keys, vals,
  # frequencies and group-by iterate a map. Elixir maps preserve insertion
  # order, so entry order is deterministic.
  # A set is a collection too — first/rest/next/seq read its members.
  # A set is a struct, so these MUST precede the is_bl_map clause or they
  # would iterate the struct's fields instead.
  # A string is seqable (elements are 1-char strings), so every
  # seq-consuming entry point needs its clause — `seq` alone is not
  # enough because these dispatch on the concrete type.
  def first(str) when is_binary(str), do: str |> seq() |> first()
  def first(%Set{} = s), do: Set.to_list(s) |> List.first()

  # A tuple reads positionally, exactly as a vector does — the same
  # invariant `nth/2` states. An empty tuple has no first, so nil.
  def first(t) when is_data_tuple(t), do: if(tuple_size(t) == 0, do: nil, else: elem(t, 0))

  # An ordered collection's first is its SMALLEST element — O(log n) via
  # :gb_trees.smallest, never a full materialisation.
  def first(%SortedSet{} = s), do: Sorted.first_key(s)

  def first(%SortedMap{} = m) do
    case Sorted.first_entry(m) do
      nil -> nil
      {k, v} -> %BeamLisp.Vector{items: {k, v}}
    end
  end

  # A record is a struct-map: iterate its public fields (and any assoc'd
  # extras), never the hidden `__struct__` key. These clauses MUST precede
  # the is_bl_map clauses or a record leaks `__struct__` into iteration.
  # A reference is not a seq-able collection — a struct-is-a-map would
  # iterate its internals.
  def first(%{__struct__: mod} = m) when is_atom(mod) and is_ref_type(m),
    do: raise(ArgumentError, "first: #{inspect(mod)} is a reference, not a collection")

  def first(%{__struct__: mod} = m) when is_atom(mod) do
    if BeamLisp.Record.record?(m), do: first(record_entries(m)), else: first(map_entries(m))
  end

  def first(m) when is_bl_map(m), do: first(map_entries(m))

  # A scalar (string, keyword, number, fn, deftype/reify tag) is not a
  # sequence, but Clojure's first is lenient — nil, not an error. References
  # still raise above; only the no-hazard scalars fall through here.
  def first(_), do: nil

  defp rest_or_empty(nil), do: []
  defp rest_or_empty(xs), do: rest(xs)

  def rest(nil), do: []
  def rest([]), do: []
  def rest([_ | t]), do: t
  def rest(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.rest(v)

  def rest(%LazySeq{} = l) do
    case LazySeq.cell(l) do
      nil -> []
      [_ | t] -> t
    end
  end

  def rest(str) when is_binary(str), do: str |> seq() |> rest_or_empty()
  def rest(%Set{} = s), do: Set.to_list(s) |> tl()

  # A tuple's rest is a LIST, not a tuple: `rest` answers a sequence in
  # this language (that is why `(rest [1 2])` is not a vector either), and
  # a shrinking tuple would be a different type at every step.
  def rest(t) when is_data_tuple(t), do: t |> Tuple.to_list() |> rest_or_empty()

  def rest(%SortedSet{} = s), do: Sorted.set_to_list(s) |> rest()

  def rest(%SortedMap{} = m), do: sorted_map_entries(m) |> rest()

  def rest(%{__struct__: mod} = m) when is_atom(mod) and is_ref_type(m),
    do: raise(ArgumentError, "rest: #{inspect(mod)} is a reference, not a collection")

  def rest(%{__struct__: mod} = m) when is_atom(mod) do
    if BeamLisp.Record.record?(m), do: rest(record_entries(m)), else: rest(map_entries(m))
  end

  def rest(m) when is_bl_map(m), do: rest(map_entries(m))

  # Lenient tail for a non-collection, matching Clojure: () — see first/1.
  def rest(_), do: []

  @doc """
  Clojure `next` ≡ `(seq (rest coll))`: nil when the remainder is empty,
  where `rest` returns an empty seq. Every recursive seq function in
  core.jank tests `(if (next xs) …)`, so the nil-vs-empty split is the
  contract. Over a LazySeq it forces exactly one cell and returns the tail
  without realizing the next one.
  """
  def next(nil), do: nil
  def next([]), do: nil
  def next(%BeamLisp.Vector{} = v), do: next_tail(BeamLisp.Vector.rest(v))
  def next([_ | t]), do: next_tail(t)

  def next(%LazySeq{} = l) do
    case LazySeq.cell(l) do
      nil -> nil
      [_ | t] -> next_tail(t)
    end
  end

  def next(str) when is_binary(str), do: next(seq(str))
  def next(%Set{} = s), do: next(Set.to_list(s))
  def next(t) when is_data_tuple(t), do: next(Tuple.to_list(t))

  def next(%SortedSet{} = s), do: next(Sorted.set_to_list(s))

  def next(%SortedMap{} = m), do: next(sorted_map_entries(m))

  def next(%{__struct__: mod} = m) when is_atom(mod) and is_ref_type(m),
    do: raise(ArgumentError, "next: #{inspect(mod)} is a reference, not a collection")

  def next(%{__struct__: mod} = m) when is_atom(mod) do
    if BeamLisp.Record.record?(m), do: next(record_entries(m)), else: next(map_entries(m))
  end

  def next(m) when is_bl_map(m), do: next(map_entries(m))

  # Lenient for a non-collection, matching Clojure: nil — see first/1.
  def next(_), do: nil

  # `next`'s tail is either a realized list (seq it → nil if empty) or a
  # LazySeq. Clojure's next is `(seq (rest x))`, so it MUST force one
  # cell to know whether the tail is empty — returning an unforced
  # LazySeq made an exhausted seq truthy, and `(when (next s) …)` is
  # how every recursive seq fn terminates. Realization is memoized, so
  # the forced cell is not recomputed by the caller.
  defp next_tail(%LazySeq{} = t) do
    if LazySeq.cell(t) == nil, do: nil, else: t
  end

  defp next_tail(t), do: seq(t)

  def cons(x, nil), do: [x]
  def cons(x, xs) when is_list(xs), do: [x | xs]
  def cons(x, %BeamLisp.Vector{} = v), do: [x | BeamLisp.Vector.to_list(v)]
  def cons(x, %LazySeq{} = l), do: [x | l]

  @doc """
  Clojure `list*`: prepend the leading args onto the final collection, which
  is treated as a sequence (`(list* a b coll)` ≡ `(cons a (cons b (seq coll)))`).
  `(list* coll)` is just `(seq coll)`; `(list*)` is nil.
  """
  def list_star(arg1, rest_list) when is_list(rest_list) do
    case rest_list do
      [] ->
        seq(arg1)

      _ ->
        [last | leading_rev] = [arg1 | rest_list] |> Enum.reverse()
        leading = Enum.reverse(leading_rev)
        leading ++ seq_to_args(last)
    end
  end

  def list_star_0, do: nil

  defp bad_map_entry(entry, n),
    do:
      raise(
        ArgumentError,
        "conj on a map takes a two-element entry, got #{n} elements: #{print_str(entry)}"
      )

  # `(conj coll)` — the reducing-fn completion arity: returns coll unchanged.
  # Clojure defines this 1-arity (identity), and `transduce`'s `(f ret)`
  # completion step delegates to it, so a non-transientable `into` target
  # (e.g. a list) can be reduced by `(transduce xform conj …)`.
  def conj(coll), do: coll

  @doc "Clojure `conj`: prepend to a list, append to a vector."
  def conj(nil, x), do: [x]
  def conj(xs, x) when is_list(xs), do: [x | xs]
  def conj(%BeamLisp.Vector{} = v, x), do: BeamLisp.Vector.conj(v, x)
  def conj(%LazySeq{} = l, x), do: [x | l]
  # Set conj adds an element (idempotent). A set is a struct, so this
  # must precede the map-entry clause below — a set of vectors is legal
  # and must not be mistaken for a map being conj-ed a [k v] entry.
  def conj(%Set{} = s, x), do: Set.add(s, x)
  # A sorted set conj's a member; a sorted map conj's a [k v] entry, the
  # same contract as a plain map. Both precede the map-entry clause below
  # for the same reason %Set{} does.
  def conj(%SortedSet{} = s, x), do: Sorted.set_add(s, x)

  def conj(%SortedMap{} = m, %BeamLisp.Vector{items: {k, v}}), do: Sorted.map_put(m, k, v)
  def conj(%SortedMap{} = m, [k, v]), do: Sorted.map_put(m, k, v)

  def conj(%SortedMap{}, other),
    do:
      raise(
        ArgumentError,
        "conj on a sorted map expects a [k v] entry, got: #{inspect(other)}"
      )
  # A reference is not conj-able — conj would otherwise fall through to the
  # map-entry clauses and silently add a field to the struct.
  def conj(%{__struct__: mod} = m, _x) when is_atom(mod) and is_ref_type(m),
    do: raise(ArgumentError, "conj: #{inspect(mod)} is a reference, not a collection")

  # Map conj with a `[k v]` entry (as `find` returns) adds that entry —
  # what select-keys does: `(conj acc (find m k))`. A record conj's the
  # entry too, preserving its type (Map.put keeps the struct); a non-record
  # struct reaching here has no conj contract and fails loudly.
  def conj(m, %BeamLisp.Vector{items: {k, v}}) when is_bl_map(m),
    do: Map.put(m, hash_key(k), v)

  # Clojure accepts any two-element SEQUENTIAL as a map entry, not only a
  # vector — anything producing seqs of pairs (`partition 2`, a `map` over
  # pairs, a destructured seq) feeds `into {}` naturally. Matching only
  # the vector shape made those crash with a FunctionClauseError.
  def conj(m, [k, v]) when is_bl_map(m), do: Map.put(m, hash_key(k), v)

  def conj(m, entry) when is_bl_map(m) and is_list(entry),
    do: bad_map_entry(entry, length(entry))

  # A wrong-shape VECTOR entry gets the same actionable error as a
  # wrong-shape list one. It used to fall through to a
  # FunctionClauseError naming an internal arity, which tells the caller
  # nothing about the entry they actually passed.
  def conj(m, %BeamLisp.Vector{} = entry) when is_bl_map(m),
    do: bad_map_entry(entry, BeamLisp.Vector.count(entry))

  def conj(%{__struct__: mod} = m, [k, v]) when is_atom(mod) do
    if BeamLisp.Record.record?(m),
      do: Map.put(m, k, v),
      else: raise(ArgumentError, "conj with a map entry is not supported on a struct")
  end

  def conj(%{__struct__: mod} = m, %BeamLisp.Vector{items: {k, v}}) when is_atom(mod) do
    if BeamLisp.Record.record?(m),
      do: Map.put(m, k, v),
      else: raise(ArgumentError, "conj with a map entry is not supported on a struct")
  end

  def count(nil), do: 0
  # A proper list is O(1) via length; a partially-realized improper one
  # (`[h | LazySeq]`, what a chunked seq's tail is) must be walked.
  def count(xs) when is_list(xs), do: if(improper?(xs), do: LazySeq.count(xs), else: length(xs))
  # Both of these are structs, and a struct is a map — they MUST precede
  # the is_bl_map clause or count returns the number of struct fields.
  # (A lazy seq quietly counted 3, its field count, for any length.)
  def count(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.count(v)
  def count(%LazySeq{} = l), do: LazySeq.count(l)
  def count(%Set{} = s), do: Set.count(s)
  def count(%SortedSet{} = s), do: Sorted.set_count(s)
  def count(%SortedMap{} = m), do: Sorted.map_count(m)
  # A tuple counts its elements. MUST precede the struct clauses below:
  # a struct is a map, not a tuple, so there is no overlap — but the
  # ordering keeps the positional shapes together and readable.
  def count(t) when is_data_tuple(t), do: tuple_size(t)
  # A record's count is its public fields (plus any assoc'd extras) —
  # map_size would count the hidden `__struct__` key too. References are
  # not collections, so they raise before this record clause.
  def count(%{__struct__: mod} = m) when is_atom(mod) and is_ref_type(m),
    do: raise(ArgumentError, "count: #{inspect(mod)} is a reference, not a collection")

  def count(%{__struct__: mod} = m) when is_atom(mod), do: map_size(m) - 1
  def count(m) when is_bl_map(m), do: map_size(m)
  def count(s) when is_binary(s), do: String.length(s)

  def empty?(%LazySeq{} = l), do: LazySeq.cell(l) == nil
  # Lists (proper or partially-realized improper ones) answer in O(1) by
  # their head alone — an improper list always has one, so it is never
  # empty. Counting here would realize a lazy tail on every call, turning
  # the self-hosted reduce's per-element `(empty? xs)` into O(n²).
  def empty?(xs) when is_list(xs), do: xs == []
  def empty?(xs), do: count(xs) == 0

  @doc "Lenient element access for sequential destructuring: nil-safe, out-of-range gives nil."
  def nth(nil, _i), do: nil
  def nth(xs, i) when is_list(xs), do: Enum.at(xs, i)
  def nth(%BeamLisp.Vector{} = v, i), do: BeamLisp.Vector.nth(v, i)

  # An Erlang tuple is a POSITIONAL collection, and the language already
  # says so where it matters most: a `[p q]` pattern matches a tuple and a
  # beam-lisp vector alike. The runtime disagreeing with the pattern layer
  # was the defect — `(let [[a b] some-tuple] …)` raised FunctionClauseError
  # from inside RT.nth, so every interop site that received a `{:ok, v}`
  # wrote `(to-list (erlang/tuple_to_list r))` by hand to get a shape the
  # language could read. That is a conversion the BEAM never needed.
  #
  # Lenient like every other sequential access here: out of range is nil,
  # never an error, so a too-short tuple destructures exactly as a
  # too-short vector does.
  def nth(t, i) when is_data_tuple(t) and is_integer(i) and i >= 0,
    do: if(i < tuple_size(t), do: elem(t, i), else: nil)

  def nth(t, _i) when is_data_tuple(t), do: nil
  def nth(%LazySeq{} = l, i) when is_integer(i) and i >= 0, do: LazySeq.nth(l, i)
  def nth(%LazySeq{} = _l, _i), do: nil

  @doc """
  Clojure's 3-arity `nth`: the element at `i`, or `not_found` when the index is
  out of range.

  Without it, reading an OPTIONAL trailing element means pre-checking `count`
  at every call site — and forgetting the check yields `nil`, which is
  indistinguishable from an element that is legitimately nil. The explicit
  default is what lets a caller tell "absent" from "present and nil", the same
  reason `get`/`get-in` carry one.
  """
  def nth(coll, i, not_found) do
    case nth(coll, i) do
      nil -> if within?(coll, i), do: nil, else: not_found
      v -> v
    end
  end

  # A nil result is ambiguous, so the bounds are checked rather than assumed:
  # a present-but-nil element must return nil, not the default.
  defp within?(nil, _i), do: false
  defp within?(coll, i) when is_integer(i) and i >= 0, do: i < count(coll)
  defp within?(_coll, _i), do: false

  @doc """
  Lenient tail access for sequential destructuring: nil-safe. Keeps
  Elixir `(coll, n)` argument order because the compiler's destructuring
  calls `BeamLisp.RT.drop/2` directly.
  """
  def drop(coll, n), do: drop_from(n, coll)

  @doc "Clojure-ordered drop: `(drop n coll)` — the beam-lisp `drop` var."
  def drop_clj(n, coll), do: drop_from(n, coll)

  defp drop_from(n, coll) when is_integer(n) and n <= 0 do
    case coll do
      nil -> []
      %LazySeq{} = l -> l
      %BeamLisp.Vector{} = v -> BeamLisp.Vector.to_list(v)
      xs when is_list(xs) -> xs
    end
  end

  defp drop_from(n, coll) when is_integer(n) and n > 0 do
    case LazySeq.cell(coll) do
      nil -> []
      [_ | t] -> drop_from(n - 1, t)
    end
  end

  # The prelude's self-hosted seq defns returned the `[]` *vector* literal
  # when the result was empty, while every non-empty result was a cons list.
  # Preserve that split so `(= (map inc []) [])` stays true under beam-lisp's
  # structural `=` (which rightly distinguishes `[]` from `()`).
  defp empty_contract([]), do: %BeamLisp.Vector{items: {}}
  defp empty_contract(result), do: result

  @doc """
  `(apply f args)` — accepts lists, vectors and lazy seqs, and dispatches
  tagged fns like any other call.
  """
  def apply_to(f, args), do: invoke(f, seq_to_args(args))

  @doc """
  Variadic `apply`: `(apply f a b args)` prepends the leading args onto the
  final seq argument. Invoked by the multi-arity tag with min=2 fixed args
  plus one rest list, so `arg1` is the first fixed arg and `rest_list` holds
  everything after it — the last element of `[arg1 | rest_list]` is the seq.
  """
  def apply_variadic(f, arg1, rest_list) when is_list(rest_list) do
    [seq_arg | leading_rev] = [arg1 | rest_list] |> Enum.reverse()
    leading = Enum.reverse(leading_rev)
    invoke(f, leading ++ seq_to_args(seq_arg))
  end

  # Normalize the final seq argument of `apply`/`list*` to a plain list:
  # nil and empty are `[]`, vectors and lazy seqs are realized.
  defp seq_to_args(nil), do: []
  defp seq_to_args(%LazySeq{} = l), do: LazySeq.to_list(l)
  defp seq_to_args(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp seq_to_args(xs) when is_list(xs), do: xs

  @doc "Clojure `seq`: nil for empty, the collection (or the lazy seq) otherwise."
  def seq(nil), do: nil
  def seq([]), do: nil
  def seq(xs) when is_list(xs), do: xs

  # A string is seqable, as in Clojure. Elements are single-character
  # STRINGS (beam-lisp has no character type), which is what `count` and
  # `subs` already assume: both are char-based, so `seq` must agree or
  # the language disagrees with itself about the same value.
  #
  # `(seq "")` is nil, matching every other empty collection.
  def seq(s) when is_binary(s) do
    case String.graphemes(s) do
      [] -> nil
      gs -> gs
    end
  end

  def seq(%BeamLisp.Vector{} = v) do
    if BeamLisp.Vector.count(v) == 0, do: nil, else: v
  end

  def seq(%LazySeq{} = l) do
    case LazySeq.cell(l) do
      nil -> nil
      _ -> l
    end
  end

  # A set's seq is its members (nil when empty); the empty set is falsy
  # in `(when (seq s) …)`, like any other empty collection.
  def seq(%SortedSet{} = s) do
    case Sorted.set_to_list(s) do
      [] -> nil
      members -> members
    end
  end

  # A sorted map seqs as ordered map entries, exactly like a plain map —
  # but with a GUARANTEED order rather than an incidental one.
  def seq(%SortedMap{} = m) do
    case sorted_map_entries(m) do
      [] -> nil
      entries -> entries
    end
  end

  # A tuple seqs to its elements, so `seq`, `first`, `rest`, `nth` and
  # `count` all agree that a tuple is positional. `nil` for the empty
  # tuple, matching every other empty collection here.
  def seq(t) when is_data_tuple(t), do: seq(Tuple.to_list(t))

  def seq(%Set{} = s) do
    case Set.to_list(s) do
      [] -> nil
      members -> members
    end
  end

  # A map's seq is its [k v] entries (nil when empty), so `(seq {:a 1})`
  # iterates like Clojure. A record is a struct-map, so its seq reads the
  # public fields, never the hidden `__struct__` key.
  def seq(%{__struct__: mod} = m) when is_atom(mod) and is_ref_type(m),
    do: raise(ArgumentError, "seq: #{inspect(mod)} is a reference, not a collection")

  def seq(%{__struct__: mod} = m) when is_atom(mod) do
    if BeamLisp.Record.record?(m), do: seq(record_entries(m)), else: seq(map_entries(m))
  end

  def seq(m) when is_bl_map(m), do: seq(map_entries(m))

  # --- type & collection predicates (Clojure-correct) ---

  @doc "`fn?`: a function value — a compiled fn, a tagged multi-arity fn, or a remote reference."
  def fn?(x) when is_function(x), do: true
  def fn?({:"$blfn", _, _}), do: true
  def fn?({:"$remote", _, _}), do: true
  def fn?(_), do: false

  @doc "`seq?`: a sequence — a proper list or a lazy seq, never a vector."
  def seq?(%LazySeq{}), do: true
  def seq?(xs) when is_list(xs), do: xs != []
  def seq?(_), do: false

  @doc "`boolean`: coercive truthiness — `true` for anything but `nil`/`false`."
  def boolean(x), do: x != nil and x != false

  @doc "`find`: the map entry for `k` in map `m` as a `[key value]` vector, else nil."
  def find(%{__struct__: mod} = m, _k) when is_atom(mod) and is_ref_type(m),
    do: raise(ArgumentError, "find: #{inspect(mod)} is a reference, not a collection")

  # A sorted map finds like a plain map — `nil` for absent, a `[k v]` entry
  # for present, so absence stays distinguishable from a nil VALUE.
  #
  # This MUST precede the generic `%{__struct__: mod}` record clause below:
  # a SortedMap is a struct, so that clause matches it first, asks
  # `Record.record?/1` (false), and falls into `find_in_map/2`, which reads
  # the STRUCT's fields (`:tree`) instead of the map's contents — returning
  # nil for every key that actually exists. Caught by probe, not by reading.
  def find(%SortedMap{} = m, k) do
    if Sorted.map_has_key?(m, k),
      do: %BeamLisp.Vector{items: {k, Sorted.map_get(m, k)}},
      else: nil
  end

  def find(%{__struct__: mod} = m, k) when is_atom(mod) do
    if BeamLisp.Record.record?(m) do
      # The internal `__struct__` key is not findable; real keys read the
      # public fields only (never recursing — the deleted map is a plain map).
      if k == :__struct__, do: nil, else: find_in_map(Map.delete(m, :__struct__), k)
    else
      find_in_map(m, k)
    end
  end

  def find(m, k) when is_bl_map(m), do: find_in_map(m, hash_key(k))

  def find(_m, _k), do: nil

  defp find_in_map(m, k) do
    case Map.fetch(m, k) do
      {:ok, v} -> %BeamLisp.Vector{items: {k, v}}
      :error -> nil
    end
  end

  @doc """
  `contains?`: KEY membership for maps, index-in-range for vectors — never
  value membership (the classic Clojure trap).
  """
  def contains?(%BeamLisp.Vector{} = v, i) when is_integer(i),
    do: i >= 0 and i < BeamLisp.Vector.count(v)

  # Set contains? is MEMBERSHIP (a set is a struct-map, so this must
  # precede the is_bl_map clause which would check the :members field).
  def contains?(%Set{} = s, x), do: Set.member?(s, x)
  # Sorted set contains? is membership; sorted map contains? is KEY
  # presence — the same asymmetry Clojure has between sets and maps.
  def contains?(%SortedSet{} = s, x), do: Sorted.set_member?(s, x)
  def contains?(%SortedMap{} = m, k), do: Sorted.map_has_key?(m, k)

  # Records report containment over their public fields only; `__struct__`
  # is internal.
  # References are not collections, so they raise rather than report a miss.
  def contains?(%{__struct__: mod} = m, _k) when is_atom(mod) and is_ref_type(m),
    do: raise(ArgumentError, "contains?: #{inspect(mod)} is a reference, not a collection")

  def contains?(%{__struct__: mod} = m, k) when is_atom(mod) do
    if BeamLisp.Record.record?(m), do: k != :__struct__ and Map.has_key?(m, k), else: Map.has_key?(m, k)
  end

  def contains?(m, k) when is_bl_map(m), do: Map.has_key?(m, hash_key(k))
  def contains?(_coll, _k), do: false

  # Keywords are BEAM atoms — but so are the booleans and nil, so a bare
  # `is_atom` would misclassify `true`/`false`/`nil` as keywords.
  def keyword?(x) when is_atom(x), do: x not in [true, false, nil]
  def keyword?(_), do: false

  def symbol?({:symbol, _}), do: true
  def symbol?(_), do: false

  def string?(x), do: is_binary(x)
  def number?(x), do: is_number(x)
  def int?(x), do: is_integer(x)
  # A record answers `true` here, as it does in Clojure, because a record IS a
  # user-facing map in this language: `count`, `seq`, `get`, `assoc`, `find`
  # and `coll?` all already treat it as one. `map?` reporting false was the
  # single dissenter, and a predicate that disagrees with every operation it
  # is supposed to guard is worse than no predicate. Non-record structs
  # (LazySeq, Vector, Set, the reference types) are NOT maps and stay false.
  # A sorted map IS a map by every operation that matters (get, assoc,
  # find, count, seq, conj), so the predicate must agree — the same
  # argument that makes a record report true.
  def map?(%SortedMap{}), do: true
  def map?(%{__struct__: mod} = x) when is_atom(mod), do: BeamLisp.Record.record?(x)
  def map?(x), do: is_bl_map(x)
  def vector?(%BeamLisp.Vector{}), do: true
  def vector?(_), do: false

  # `struct?` / `associative?` — the trichotomy `map?` alone could not express,
  # and the source of a whole class of interop bug.
  #
  # `map?` answers "is this a beam-lisp MAP?" — true for a bl map or a bl
  # record, FALSE for a foreign BEAM struct (a `%ReqLLM.Response{}`, an Ecto
  # schema), by the deliberate decision documented above. But a foreign struct
  # is still an ASSOCIATIVE value: `(Map/get s :field)` reads it, `get-in`
  # walks it. Code that branched on `map?` to decide "can I read fields off
  # this?" took the wrong arm on every foreign struct and mishandled it
  # silently (a gateway once leaked a raw error struct into a 500 exactly
  # here). The missing predicate is WHY `map?` was misused.
  #
  #   map?         ⊆ associative?      — every bl map is associative
  #   struct?      the foreign side     — any %_{} , bl record OR foreign
  #   associative? = struct? ∪ bl-map ∪ vector   — "I can `get` by key/index"
  #
  # `struct?` is true for a bl RECORD or a FOREIGN struct, but NOT for
  # beam-lisp's own internal value structs — a vector, set, sorted map/set and
  # lazy-seq are all `%_{}` under the hood, yet they are the language's
  # collections, not "structs" a user reasons about. Excluding them keeps the
  # predicate meaningful: `(and (struct? x) (not (map? x)))` names "a foreign
  # struct" precisely, which is the guard interop code wants, and a vector
  # (which `map?` already reports false) does not sneak through it.
  @doc """
  `struct?`: a user/foreign BEAM struct — a bl record OR a foreign struct (a
  `%Date{}`, `%ReqLLM.Response{}`). FALSE for beam-lisp's own collection
  structs (vector, set, sorted map/set, lazy-seq) and reference types, which
  are the language's values rather than structs a program inspects.
  """
  def struct?(%BeamLisp.Vector{}), do: false
  def struct?(%Set{}), do: false
  def struct?(%SortedMap{}), do: false
  def struct?(%SortedSet{}), do: false
  def struct?(%LazySeq{}), do: false
  def struct?(%{__struct__: mod} = x) when is_atom(mod), do: not is_ref_type(x)
  def struct?(_), do: false

  @doc """
  `associative?`: a value fields can be read from by key or index — a bl map,
  a bl record, a foreign struct, or a vector. The predicate to branch on when
  the question is "can I `get` into this?", where `map?` is the wrong one
  because it excludes foreign structs that `Map/get` reads fine.
  """
  # bl map (incl. SortedMap, which map? already covers) ∪ vector ∪ any
  # user/foreign struct. Built ON `struct?`/`map?`/`vector?` so the internal
  # non-associative structs (Set, SortedSet, LazySeq) are excluded for free:
  # none of the three is true for them.
  def associative?(x), do: struct?(x) or map?(x) or vector?(x)

  @doc "`list?`: a proper list (incl. the empty list) — never a vector, map, or nil."
  def list?(x) when is_list(x), do: true
  def list?(_), do: false

  def coll?(x) when is_list(x), do: true
  def coll?(%BeamLisp.Vector{}), do: true
  def coll?(%LazySeq{}), do: true
  def coll?(%Set{}), do: true
  def coll?(%SortedSet{}), do: true
  def coll?(%SortedMap{}), do: true
  # A reference is a struct but never a collection.
  def coll?(%{__struct__: mod} = m) when is_atom(mod) and is_ref_type(m), do: false
  # Records are user-facing maps, so they are collections.
  def coll?(%{__struct__: mod}) when is_atom(mod), do: true
  def coll?(m) when is_bl_map(m), do: true
  def coll?(_), do: false

  @doc "`ident?`: a keyword or a symbol."
  def ident?(x) when is_atom(x), do: x not in [true, false, nil]
  def ident?({:symbol, _}), do: true
  def ident?(_), do: false

  # --- sets ---------------------------------------------------------
  # The set type (BeamLisp.Set, a MapSet wrapper). `#{...}` literals are
  # a reader concern not yet wired; these fns build and read sets.

  @doc "`(set coll)` — a set of the distinct elements of coll; a set input is returned unchanged."
  def set(%Set{} = s), do: s
  def set(coll), do: coll |> seq() |> set_from_seq()

  defp set_from_seq(nil), do: Set.new()
  defp set_from_seq(s), do: Set.new(seq_to_args(s))

  @doc "`set?`: true for a set — hashed or ordered."
  def set?(%Set{}), do: true
  def set?(%SortedSet{}), do: true
  def set?(_), do: false

  @doc "`(disj set x)` — the set without x (idempotent)."
  def disj(%Set{} = s, x), do: Set.del(s, x)
  def disj(%SortedSet{} = s, x), do: Sorted.set_del(s, x)

  # --- sorted collections ------------------------------------------
  # The ordered siblings of `set`/map. Their vocabulary (sorted-map,
  # sorted-set, subseq, rsubseq) is defined in priv/core.bl over these
  # primitives — Elixir keeps only what needs :gb_trees.

  @doc "`(sorted-map & kvs)` — an ordered map from flat key/value args."
  def sorted_map(args) do
    args
    |> seq_to_args()
    |> Enum.chunk_every(2)
    |> Enum.reduce(Sorted.map_new(), fn
      [k, v], acc ->
        Sorted.map_put(acc, k, v)

      [k], _acc ->
        raise(ArgumentError, "sorted-map: no value supplied for key #{inspect(k)}")
    end)
  end

  @doc "`(sorted-set & xs)` — an ordered set of the given elements."
  def sorted_set(args), do: Sorted.set_new(seq_to_args(args))

  @doc "`(sorted-map-of coll)` — an ordered map from a collection of `[k v]` entries."
  def sorted_map_of(coll) do
    coll
    |> seqable()
    |> Enum.reduce(Sorted.map_new(), fn
      %BeamLisp.Vector{items: {k, v}}, acc -> Sorted.map_put(acc, k, v)
      [k, v], acc -> Sorted.map_put(acc, k, v)
      other, _acc -> raise(ArgumentError, "sorted-map-of: not a [k v] entry: #{inspect(other)}")
    end)
  end

  @doc "`(sorted-set-of coll)` — an ordered set of a collection's distinct elements."
  def sorted_set_of(coll), do: Sorted.set_new(seqable(coll))

  @doc "`sorted?`: true for an ordered map or set."
  def sorted?(%SortedMap{}), do: true
  def sorted?(%SortedSet{}), do: true
  def sorted?(_), do: false

  @doc """
  `(sorted-dissoc m k)` — an ordered map without `k` (idempotent).

  Exists because `dissoc` in `priv/core.bl` reaches for `Map/delete`, which
  on a SortedMap would delete a struct FIELD (or silently no-op) rather
  than a tree entry — leaving the key still present. core dispatches here
  for ordered maps.
  """
  def sorted_dissoc(%SortedMap{} = m, k), do: Sorted.map_delete(m, k)

  @doc "`sorted-map?`: true only for an ordered MAP (a sorted set answers false)."
  def sorted_map?(%SortedMap{}), do: true
  def sorted_map?(_), do: false

  @doc "`sorted-set?`: true only for an ordered SET (a sorted map answers false)."
  def sorted_set?(%SortedSet{}), do: true
  def sorted_set?(_), do: false

  @doc "`(last-key coll)` — the largest key/member, or nil when empty. O(log n)."
  def last_key(%SortedMap{} = m), do: Sorted.last_key(m)
  def last_key(%SortedSet{} = s), do: Sorted.last_key(s)

  @doc "`(last-entry m)` — the largest `[k v]` entry of a sorted map, or nil."
  def last_entry(%SortedMap{} = m) do
    case Sorted.last_entry(m) do
      nil -> nil
      {k, v} -> %BeamLisp.Vector{items: {k, v}}
    end
  end

  @doc """
  `(subseq coll start stop)` — ascending elements between inclusive bounds.

  `nil` bounds are unbounded. A sorted set yields members; a sorted map
  yields `[k v]` entries. The scan starts AT the lower bound rather than
  filtering from the beginning — the property index range-scans need.
  """
  def subseq(coll, start, stop), do: range_seq(coll, start, stop, :asc)

  @doc "`(rsubseq coll start stop)` — as `subseq`, descending."
  def rsubseq(coll, start, stop), do: range_seq(coll, start, stop, :desc)

  defp range_seq(coll, start, stop, dir) do
    # `nil` is the language-level "unbounded" marker; every other value is
    # a real key, TAGGED so it can never be confused with the sentinel.
    # (Untagged, a scan for the legal keyword `:unbounded` was silently
    # read as "no bound" and returned the whole collection.)
    lo = if start == nil, do: :unbounded, else: {:bound, start}
    hi = if stop == nil, do: :unbounded, else: {:bound, stop}

    entries =
      case dir do
        :asc -> Sorted.subseq_entries(coll, lo, hi)
        :desc -> Sorted.rsubseq_entries(coll, lo, hi)
      end

    case coll do
      %SortedSet{} -> Enum.map(entries, fn {k, _} -> k end)
      %SortedMap{} -> Enum.map(entries, fn {k, v} -> %BeamLisp.Vector{items: {k, v}} end)
    end
  end

  @doc "`sequential?`: a list, vector, or lazy seq — never a map, set, or string."
  def sequential?(%BeamLisp.Vector{}), do: true
  def sequential?(%LazySeq{}), do: true
  def sequential?(x) when is_list(x), do: true
  def sequential?(_), do: false

  @doc """
  `(tree-seq branch? children root)` — depth-first traversal of the tree
  rooted at `root`, yielding `root` then each child subtree in turn.
  Realized eagerly (a finite flatten input); Clojure's is lazy, but the
  emitted sequence is identical.
  """
  def tree_seq(branch?, children, root) do
    if invoke(branch?, [root]) do
      kids = invoke(children, [root]) |> seqable() |> Enum.flat_map(&tree_seq(branch?, children, &1))
      [root | kids]
    else
      [root]
    end
  end

  # --- sort / compare ------------------------------------------------

  @doc """
  `(compare a b)` — a total order over the common beam-lisp types,
  mirroring Clojure: nil < false < true < numbers < strings < symbols <
  keywords < collections < anything else. Within a type, natural order
  (numeric, lexicographic, element-wise for collections). Not covered:
  the JVM-specific interop cases (chars, regexes, other Java types) —
  those fall to a generic rank.
  """
  def compare(a, b) do
    cond do
      a == b -> 0
      rank(a) != rank(b) -> sign(rank(a) - rank(b))
      true -> cmp_same(rank(a), a, b)
    end
  end

  defp rank(nil), do: 0
  defp rank(false), do: 1
  defp rank(true), do: 2
  defp rank(x) when is_number(x), do: 3
  defp rank(x) when is_binary(x), do: 4
  defp rank({:symbol, _}), do: 5
  defp rank(x) when is_atom(x), do: 6
  # SEQUENTIAL collections share rank 7 and compare element-wise: a
  # vector, a lazy seq and a list holding the same elements ARE equal in
  # this language, so they must also compare equal.
  # A VECTOR ranks just above a cons list, because `=` keeps them
  # distinct (wave 3's `[] ≠ ()` split, pinned in wave26_laziness_test).
  # Sharing one rank made `compare` answer 0 for a pair `=` calls
  # different — the same defect as BUG-018, and it left the datom codec
  # with no single order to project (BUG-019).
  #
  # They stay ADJACENT so the two still sort together; only the tie
  # between them is broken, and broken the way `=` already breaks it.
  defp rank(x) when is_list(x), do: 7
  # A LAZY SEQ ranks with VECTORS, not with cons lists, because `=`
  # puts it there: `(= [1 2] (map identity [1 2]))` is true while
  # `(= [1 2] '(1 2))` is false. Ranking it as a list made `compare`
  # disagree with `=` about the same pair — the defect BUG-019 fixed for
  # vector-vs-list, reappearing one type over.
  defp rank(%LazySeq{}), do: 7.1
  defp rank(%BeamLisp.Vector{}), do: 7.1

  # Sets and maps are NOT sequential and are not equal to a vector, so
  # they get their own ranks. Sharing rank 7 made `(compare [] {})`
  # answer 0 while `(= [] {})` answered false — the same
  # distinct-values-declared-equal defect as BUG-018, one type family up.
  defp rank(%Set{}), do: 7.3
  defp rank(%SortedSet{}), do: 7.3
  defp rank(%SortedMap{}), do: 7.6
  # is_map-ok: assigning a comparison rank to plain maps and structs, not
  # performing a collection operation.
  defp rank(x) when is_map(x), do: 7.6

  # Ranks past the Clojure-shaped ones, in ERLANG's term order:
  #
  #   number < atom < reference < fun < port < pid < tuple < map < list
  #
  # These used to share a single rank 8 whose comparator returned 0, so
  # any two DISTINCT tuples (or pids, ports, refs, funs) compared EQUAL.
  # That is not an imprecision, it is an inconsistency, and `sort`,
  # `distinct` and `sorted-set` all inherit it: a sorted set could
  # silently hold one element where two were put in (BUG-018).
  defp rank(x) when is_reference(x), do: 8
  defp rank(x) when is_function(x), do: 9
  defp rank(x) when is_port(x), do: 10
  defp rank(x) when is_pid(x), do: 11
  defp rank(x) when is_tuple(x), do: 12
  defp rank(_), do: 13

  defp cmp_same(3, a, b), do: sign_num(a, b)
  defp cmp_same(4, a, b), do: sign_str(a, b)
  defp cmp_same(5, a, b), do: sign_str(sym_name(a), sym_name(b))
  defp cmp_same(6, a, b), do: sign_str(Atom.to_string(a), Atom.to_string(b))
  defp cmp_same(7, a, b), do: compare_seqs(a, b)
  defp cmp_same(7.1, a, b), do: compare_seqs(a, b)
  defp cmp_same(7.3, a, b), do: compare_seqs(seq(a), seq(b))
  defp cmp_same(7.6, a, b), do: compare_seqs(seq(a), seq(b))

  # A tuple compares by ARITY FIRST, then element-wise. That is Erlang's
  # own rule (`{9} < {1,1}`), and the datom codec encodes tuples the same
  # way, so the two agree.
  defp cmp_same(12, a, b) do
    sa = tuple_size(a)
    sb = tuple_size(b)

    if sa != sb do
      sign(sa - sb)
    else
      compare_seqs(Tuple.to_list(a), Tuple.to_list(b))
    end
  end

  # Reference, fun, port, pid, and anything unforeseen: no meaningful
  # VALUE order exists, so defer to Erlang's — consistent and stable,
  # even though arbitrary. Returning 0 here was the bug: it claimed two
  # different terms were the same term.
  defp cmp_same(_, a, b), do: erlang_order(a, b)

  defp erlang_order(a, b) when a < b, do: -1
  defp erlang_order(a, b) when a > b, do: 1
  defp erlang_order(_, _), do: 0

  defp sign_num(a, b) when a < b, do: -1
  defp sign_num(_a, _b), do: 1
  defp sign_str(a, b) when a < b, do: -1
  defp sign_str(_a, _b), do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(n) when n > 0, do: 1
  defp sign(_), do: 0

  defp sym_name({:symbol, n}), do: n

  defp compare_seqs(a, b) do
    # seq of a vector is the vector itself (a struct), so normalize both
    # operands to plain lists before walking element-wise.
    compare_lists(seq_to_args(seq(a)), seq_to_args(seq(b)))
  end

  defp compare_lists([], []), do: 0
  defp compare_lists([], _), do: -1
  defp compare_lists(_, []), do: 1

  defp compare_lists([ha | ta], [hb | tb]) do
    case compare(ha, hb) do
      0 -> compare_lists(ta, tb)
      c -> c
    end
  end

  @doc "`(sort coll)` / `(sort comp coll)` — a stable sorted seq (a list)."
  def sort(coll), do: sort(&compare/2, coll)

  def sort(comp, coll) do
    coll |> seqable() |> Enum.sort(fn a, b -> invoke(comp, [a, b]) <= 0 end) |> empty_contract()
  end

  # --- cpp/* interop ------------------------------------------------
  # jank writes `(cpp/jank.runtime.name x)` for its C++ primitives.
  # beam-lisp maps that qualified name onto a BEAM function with the
  # same semantics, so upstream core.jank slices load unchanged.

  @doc "jank's `cpp/jank.runtime.name`: the name String of a string, symbol, or keyword."
  def name_of(x) when is_binary(x), do: x
  def name_of({:symbol, n}), do: name_part(n)
  def name_of(x) when is_atom(x) and x not in [true, false, nil], do: name_part(Atom.to_string(x))
  def name_of(_), do: nil

  @doc "jank's `cpp/jank.runtime.namespace_`: the namespace String, or nil."
  def namespace_of({:symbol, n}), do: ns_part(n)
  def namespace_of(x) when is_atom(x) and x not in [true, false, nil], do: ns_part(Atom.to_string(x))
  def namespace_of(_), do: nil

  @doc "jank's `cpp/jank.runtime.keyword`: a keyword with the given namespace and name."
  def keyword_of(ns, name) when is_binary(name) do
    {ns, name} = split_keyword(ns, name)
    # Through the guard, not String.to_atom/1: a keyword built at
    # RUNTIME comes from data, and data can be unbounded in a way source
    # text is not. A loop interning one atom per input row is exactly
    # the shape that fills the table, and a full atom table aborts the
    # VM uncatchably.
    BeamLisp.AtomGuard.to_atom(if(is_nil(ns), do: name, else: ns <> "/" <> name))
  end

  def keyword_of(ns, {:symbol, n}), do: keyword_of(ns, n)

  defp split_keyword(nil, name) do
    case String.split(name, "/", parts: 2) do
      [ns, n] -> {ns, n}
      _ -> {nil, name}
    end
  end

  defp split_keyword(ns, name), do: {ns, name}

  defp name_part(n) do
    case String.split(n, "/", parts: 2) do
      [_, name] -> name
      _ -> n
    end
  end

  defp ns_part(n) do
    case String.split(n, "/", parts: 2) do
      [ns, _] -> ns
      _ -> nil
    end
  end

  @doc "jank's `cpp/jank.runtime.reduced`: wrap x so a `reduce` terminates early with it."
  def reduced(x), do: %BeamLisp.Reduced{value: x}

  @doc "jank's `cpp/jank.runtime.is_reduced`: true exactly for a reduced wrapper."
  def reduced?(%BeamLisp.Reduced{}), do: true
  def reduced?(_), do: false

  @doc """
  jank's `cpp/jank.runtime.reduce` — `(reduce f init coll)`. Iterates via
  LazySeq.cell (so vectors, lazy seqs, sets and maps all fold), and
  short-circuits the moment the step fn returns a Reduced, returning the
  *unwrapped* value — Clojure peels the sentinel at the halting point, so
  `transduce`'s `(f ret)` sees a plain result, not a boxed one.
  """
  def reduce(f, init, coll), do: reduce_loop(f, init, LazySeq.cell(coll))

  defp reduce_loop(_f, acc, nil), do: acc
  defp reduce_loop(_f, acc, []), do: acc
  defp reduce_loop(f, acc, [h | t]) do
    case invoke(f, [acc, h]) do
      %BeamLisp.Reduced{} = r -> r.value
      acc2 -> reduce_loop(f, acc2, LazySeq.cell(t))
    end
  end

  @doc "jank's `cpp/jank.runtime.peek`: a vector's last element, a seq's first; nil when empty."
  def peek(%BeamLisp.Vector{} = v) do
    case BeamLisp.Vector.to_list(v) do
      [] -> nil
      xs -> List.last(xs)
    end
  end

  def peek([]), do: nil
  def peek(nil), do: nil
  # An ordered collection is not a STACK. Clojure's peek/pop are defined on
  # list/queue/vector only, and raise otherwise. Without these clauses the
  # catch-all below answers `first`/`rest`, which looks plausible — `(peek
  # sorted-set)` returning the smallest element reads like a feature — but
  # it is a different operation wearing the same name. Fail loudly.
  def peek(%SortedSet{}),
    do: raise(ArgumentError, "peek: a sorted set is not a stack (use first / last-key)")

  def peek(%SortedMap{}),
    do: raise(ArgumentError, "peek: a sorted map is not a stack (use first / last-entry)")

  def peek(coll), do: first(coll)

  @doc "jank's `cpp/jank.runtime.pop`: a vector without its last, a seq without its first; empty throws."
  def pop(%BeamLisp.Vector{} = v) do
    case BeamLisp.Vector.to_list(v) do
      [] -> raise(ArgumentError, "Can't pop empty vector")
      xs -> BeamLisp.Vector.new(Enum.drop(xs, -1))
    end
  end

  def pop([]), do: raise(ArgumentError, "Can't pop empty list")
  def pop(nil), do: raise(ArgumentError, "Can't pop empty list")
  def pop([_ | t]), do: t
  # See `peek/1`: not stacks. `pop` was worse than `peek` — it returned a
  # plain LIST, silently changing the collection's type as well as its
  # meaning.
  def pop(%SortedSet{}),
    do: raise(ArgumentError, "pop: a sorted set is not a stack (use disj)")

  def pop(%SortedMap{}),
    do: raise(ArgumentError, "pop: a sorted map is not a stack (use dissoc)")

  def pop(coll), do: rest(coll)

  @doc """
  jank's `cpp/jank.runtime.promoting_inc`. On the BEAM integers are
  arbitrary precision, so `+ 1` can never overflow — the promotion jank's
  C++ `inc'` performs is inherent in the representation, not a step we
  need to take.
  """
  def promoting_inc(x), do: x + 1

  @doc "jank's `cpp/jank.runtime.is_ratio`: beam-lisp has no Ratio type (no exact rationals), so nothing is one."
  def ratio?(_), do: false

  @doc "jank's `cpp/jank.runtime.is_big_decimal`: beam-lisp has no BigDecimal type, so nothing is one."
  def decimal?(_), do: false

  # NB: `sorted?/1` now lives with the sorted-collection primitives above
  # (it answers true for SortedMap/SortedSet since PLAN-033 wave 1). jank's
  # `cpp/jank.runtime.is_sorted` maps onto that same fn — the vendored
  # slice's `(sorted? {})` stays false because a PLAIN map is still
  # unsorted, but a genuine ordered collection now answers true, which is
  # the more faithful answer to jank's question rather than a stub.

  @doc "jank's `cpp/jank.runtime.is_nan`: true for a NaN float (the only value unequal to itself)."
  def nan?(x) when is_float(x), do: x != x
  def nan?(_), do: false

  @doc """
  Clojure `rem`: the remainder of a/b, with the sign of the *dividend* a.
  This is deliberately not `mod` (sign of the divisor) — the two differ on
  negative operands, which is why upstream defines `mod` in terms of `rem`.
  Elixir's `rem` is Erlang's, which is exactly Clojure's: rem(-7, 3) is -1.
  """
  def rem(a, b), do: :erlang.rem(a, b)

  @doc "jank's `float?`: true for floating-point values. On the BEAM that is `is_float/1`; upstream jank spells the derived predicate `double?`."
  def float?(x), do: is_float(x)

  @doc """
  jank's `transientable?`: whether a collection supports `(transient coll)`.
  Mirrors `BeamLisp.Transient.transient/1` exactly, so it can never lie and
  silently send `into` down the wrong path: beam-lisp vectors, sets, and maps
  (a map on the BEAM is any struct or plain map) get a transient view; lists,
  lazy seqs, and non-collections do not. `(transient coll)` and this predicate
  must stay in lockstep — a drift here is exactly the silent-slow/ silent-wrong
  bug the doc warns about.
  """
  def transientable?(%BeamLisp.Vector{}), do: true
  def transientable?(%Set{}), do: true
  # Ordered collections have no transient view: :gb_trees is already a
  # persistent structure with cheap updates, and a mutable ordered
  # transient would need a second implementation for no measured gain.
  def transientable?(%SortedSet{}), do: false
  def transientable?(%SortedMap{}), do: false
  # A lazy seq is a struct, so it is a map — but it is not transientable.
  def transientable?(%LazySeq{}), do: false
  # A reference is a struct but never transientable (its transient view
  # would be a map transient over the struct's internals).
  def transientable?(%{__struct__: mod} = m) when is_atom(mod) and is_ref_type(m), do: false
  # Records and plain maps get a map transient view.
  def transientable?(%{__struct__: mod}) when is_atom(mod), do: true
  def transientable?(m) when is_bl_map(m), do: true
  def transientable?(_), do: false

  @doc "jank's `cpp/jank.runtime.bit_not`: bitwise complement, `~x` (two's-complement negation minus one)."
  def bit_not(x), do: :erlang.bnot(x)

  # Whether `x` is an unordered collection (set or map) rather than a
  # sequence. Records are maps by design, so they count.
  defp set_or_map?(%Set{}), do: true
  defp set_or_map?(%SortedSet{}), do: true
  defp set_or_map?(%SortedMap{}), do: true
  # is_map-ok: classifying a value for equality dispatch, not performing
  # a collection operation.
  defp set_or_map?(x) when is_map(x) and not is_struct(x), do: true
  defp set_or_map?(%BeamLisp.Vector{}), do: false
  defp set_or_map?(%LazySeq{}), do: false
  defp set_or_map?(x) when is_struct(x), do: BeamLisp.Record.record?(x)
  defp set_or_map?(_), do: false

  @doc """
  Clojure `=`: realize-and-compare element-wise with short-circuiting, so
  `(= (range) '(1 2))` stops at the first mismatch instead of realizing an
  infinite seq. A lazy/improper operand always walks; a vector compares
  element-wise too (so a lazy value nested inside one realizes), but a
  vector never equals a list — wave 3's `[] ≠ ()` split.
  """
  def eqv(a, b) do
    cond do
      # A FUNCTION is compared by identity and never walked. Elixir's
      # `Enumerable` is implemented for arity-2 functions (that is how a
      # reducer is enumerated), so a lazy walk over one silently tried to
      # ENUMERATE it, and comparing any other arity raised
      # `protocol Enumerable not implemented for Function`.
      #
      # `=` must be total: it answers true or false for any two values a
      # caller can hold. Raising for one of them makes every collection
      # containing a function a landmine — `distinct`, set membership and
      # `contains?` all route through here.
      is_function(a) or is_function(b) ->
        a === b

      # Walk whenever an operand is lazy *or* an improper list (a
      # partially-realized `[h | LazySeq]`), so a lazy interleave result —
      # or an empty lazy seq against either `()` or `[]` — compares
      # element-wise instead of failing the structural `==`.
      # A SET or MAP is never equal to a sequence, however its elements
      # line up. Checked BEFORE the lazy walk, which realizes both sides
      # and compares element-wise without asking what kind of thing it
      # is holding — so `(= #{1 2} (map identity [1 2]))` answered TRUE
      # while `(= #{1 2} [1 2])` answered false, for the same set and
      # the same two elements.
      set_or_map?(a) != set_or_map?(b) ->
        false

      # Walk whenever an operand is lazy *or* an improper list (a
      # partially-realized `[h | LazySeq]`), so a lazy interleave result —
      # or an empty lazy seq against either `()` or `[]` — compares
      # element-wise instead of failing the structural `==`.
      LazySeq.lazy?(a) or LazySeq.lazy?(b) or improper?(a) or improper?(b) ->
        eqv_walk(a, b)

      # A vector is a distinct type: two vectors compare element-wise (so a
      # lazy element nested inside one — e.g. `(split-with …)` puts
      # take-while results in a vector — realizes against its sibling), but
      # a vector vs a non-vector is never equal (empty `[]` stays `≠ ()`).
      vector?(a) or vector?(b) ->
        eqv_vector(a, b)

      # An ordered collection equals its HASHED sibling with the same
      # contents — Clojure's contract: sortedness is an index property, not
      # part of a value's identity. `Kernel.==` would compare the backing
      # `:gb_trees` against a `MapSet` and answer false for two collections
      # the language considers equal, which would then break `distinct`,
      # set membership, and any test asserting against a plain literal.
      sorted_map?(a) or sorted_map?(b) ->
        eqv_as_map(a, b)

      sorted_set?(a) or sorted_set?(b) ->
        eqv_as_set(a, b)

      # Two plain maps compare ENTRY-WISE rather than by `Kernel.==`, so a
      # value carrying metadata equals its plain twin: metadata is
      # invisible to `=`, including when it sits one level down. The raw
      # term comparison sees the struct field and answers false for two
      # maps the language considers equal.
      is_bl_map(a) and is_bl_map(b) ->
        eqv_as_map(a, b)

      # Two sets likewise: membership is by normalized value.
      match?(%Set{}, a) and match?(%Set{}, b) ->
        eqv_as_set(a, b)

      true ->
        Kernel.==(a, b)
    end
  end

  # Compare any two map-shaped values (sorted or plain) by entries. Keys
  # are compared with `==` via lookup; VALUES go through `eqv/2` so a lazy
  # or vector value nested inside still compares element-wise.
  defp eqv_as_map(a, b) do
    if map?(a) and map?(b) do
      ea = map_entry_pairs(a)
      eb = map_entry_pairs(b)

      length(ea) == length(eb) and
        Enum.all?(ea, fn {k, v} ->
          case find(b, k) do
            %BeamLisp.Vector{items: {_k, bv}} -> eqv(v, bv)
            nil -> false
          end
        end)
    else
      false
    end
  end

  defp eqv_as_set(a, b) do
    if set?(a) and set?(b) do
      la = set_members(a)
      lb = set_members(b)
      length(la) == length(lb) and Enum.all?(la, &contains?(b, &1))
    else
      false
    end
  end

  defp map_entry_pairs(%SortedMap{} = m), do: Sorted.map_to_list(m)

  defp map_entry_pairs(m) do
    m |> seq() |> seq_to_args() |> Enum.map(fn %BeamLisp.Vector{items: {k, v}} -> {k, v} end)
  end

  defp set_members(%SortedSet{} = s), do: Sorted.set_to_list(s)
  defp set_members(%Set{} = s), do: Set.to_list(s)

  defp eqv_vector(a, b) do
    if vector?(a) and vector?(b) do
      la = BeamLisp.Vector.to_list(a)
      lb = BeamLisp.Vector.to_list(b)
      length(la) == length(lb) and Enum.zip(la, lb) |> Enum.all?(fn {x, y} -> eqv(x, y) end)
    else
      false
    end
  end

  defp eqv_walk(a, b) do
    ca = LazySeq.cell(a)
    cb = LazySeq.cell(b)

    cond do
      is_nil(ca) and is_nil(cb) ->
        true

      is_nil(ca) or is_nil(cb) ->
        false

      match?([_ | _], ca) and match?([_ | _], cb) ->
        [ha | ta] = ca
        [hb | tb] = cb
        if eqv(ha, hb), do: eqv_walk(ta, tb), else: false

      true ->
        Kernel.==(ca, cb)
    end
  end

  # --- lazy sequences -------------------------------------------------
  # The seq fns (`map`, `filter`, `range`, `concat`, `take-while`, …) are
  # uniformly lazy, as in Clojure: they compose without realizing what a
  # consumer never asks for, and they chunk at 32 so a small strict map
  # does not pay per-element LazySeq overhead. `seq`/`first`/`rest` (and the
  # forcing folds `reduce`/`take`/`count`/`doall`) are the forcing boundary;

  # Clojure treats nil as an empty seq everywhere a seq is expected:
  # `(map f nil)` is `()`, not an error. An exhausted `& rest` binds
  # nil, so upstream code passes nil into seq fns constantly.
# A map becomes a seq of `[k v]` entry vectors — the Clojure MapEntry
  # shape — so first/rest/seq/next and reduce all see pairs. Elixir map
  # enumeration is insertion-ordered, keeping key order deterministic.
  defp map_entries(m), do: for({k, v} <- m, do: %BeamLisp.Vector{items: {k, v}})

  # A sorted map's entries, in KEY ORDER — the same `[k v]` entry vectors a
  # plain map produces, so every downstream consumer (destructuring, `into`,
  # `for`) works unchanged; only the order is now guaranteed.
  defp sorted_map_entries(%SortedMap{} = m),
    do: Sorted.map_to_list(m) |> Enum.map(fn {k, v} -> %BeamLisp.Vector{items: {k, v}} end)

  # A record's entries: its public fields (plus any assoc'd extras) as
  # [k v] entry vectors. `for`/`Enum` over a struct raise (no Enumerable),
  # so records are read through Map.to_list with the internal `__struct__`
  # key dropped.
  defp record_entries(r) do
    r
    |> Map.to_list()
    |> Enum.reject(fn {k, _} -> k == :__struct__ end)
    |> Enum.map(fn {k, v} -> %BeamLisp.Vector{items: {k, v}} end)
  end

  defp seqable(nil), do: []
  # A set is a struct-map; iterating it via Enum would walk its fields,
  # so map/filter read its members instead.
  defp seqable(%Set{} = s), do: Set.to_list(s)
  # Ordered collections iterate in key order — that guarantee is the
  # entire reason they exist, so map/filter/reduce must honour it.
  defp seqable(%SortedSet{} = s), do: Sorted.set_to_list(s)
  defp seqable(%SortedMap{} = m), do: sorted_map_entries(m)
  # A record iterates as its public entries, not its struct fields.
  defp seqable(%{__struct__: mod} = r) when is_atom(mod) do
    if BeamLisp.Record.record?(r), do: record_entries(r), else: r
  end
  defp seqable(coll), do: coll

  def map(f, coll), do: lazy_map(f, seqable(coll))

  defp lazy_map(f, coll) do
    LazySeq.new(fn ->
      case LazySeq.cell(coll) do
        nil -> nil
        [h | t] ->
          {elems, rest} = map_chunk(f, [invoke(f, [h])], t, LazySeq.chunk_size() - 1)

          # An exhausted source ends the chunk as a proper list (no empty
          # LazySeq tail), so `(map f [1 2 3])` is a proper list a caller
          # can hand to `Vector.new` or `length`. Only a non-empty rest
          # appends a lazy tail.
          if is_nil(rest),
            do: elems,
            else: LazySeq.chain(elems, fn -> lazy_map(f, rest) end)
      end
    end)
  end

  defp map_chunk(_f, acc, rest, 0), do: {Enum.reverse(acc), rest}

  defp map_chunk(f, acc, rest, n) do
    case LazySeq.cell(rest) do
      nil -> {Enum.reverse(acc), nil}
      [h | t] -> map_chunk(f, [invoke(f, [h]) | acc], t, n - 1)
    end
  end

  # Multi-collection `(map f c1 c2 …)` — stops at the *shortest* input,
  # exactly like Clojure. Each coll is re-seq'd per step so a lazy input is
  # only ever realized as far as the fold needs it.
  def map_multi(f, c1, rest_colls), do: lazy_multi_map(f, [c1 | rest_colls])

  defp lazy_multi_map(f, colls) do
    LazySeq.new(fn ->
      seqs = Enum.map(colls, &seq/1)

      if Enum.any?(seqs, &is_nil/1) do
        nil
      else
        [invoke(f, Enum.map(seqs, &first/1)) | lazy_multi_map(f, Enum.map(seqs, &rest/1))]
      end
    end)
  end

  def filter(pred, coll), do: lazy_filter(pred, seqable(coll))

  # Chunked like map: each thunk collects up to `@chunk_size` elements that
  # pass `pred` (skipping non-matches without yielding them), so a consumer
  # that stops early never realizes more than one source chunk past it.
  defp lazy_filter(pred, coll) do
    LazySeq.new(fn ->
      case skip_filter(pred, coll) do
        nil -> nil
        [h | t] ->
          {elems, rest} = filter_chunk(pred, [h], t, LazySeq.chunk_size() - 1)
          if is_nil(rest),
            do: elems,
            else: LazySeq.chain(elems, fn -> lazy_filter(pred, rest) end)
      end
    end)
  end

  defp filter_chunk(_pred, acc, coll, 0), do: {Enum.reverse(acc), coll}

  defp filter_chunk(pred, acc, coll, n) do
    case skip_filter(pred, coll) do
      nil -> {Enum.reverse(acc), nil}
      [h | t] -> filter_chunk(pred, [h | acc], t, n - 1)
    end
  end

  defp skip_filter(pred, coll) do
    case LazySeq.cell(coll) do
      nil -> nil
      [h | t] -> if invoke(pred, [h]), do: [h | t], else: skip_filter(pred, t)
    end
  end

  @doc """
  `(range)` is an infinite lazy seq. Bounded `(range end)` and
  `(range start end)` are lazy too, so `(take 5 (map f (range 1000000)))`
  realizes only the chunk `take` asks for instead of every element. An
  empty or exhausted range is an empty lazy seq (`()`), not a `[]` vector.
  """
  def range(), do: LazySeq.new(fn -> range_chunk(0, nil) end)
  def range(end_), do: range(0, end_)
  def range(start, end_), do: LazySeq.new(fn -> range_chunk(start, end_) end)

  # One chunk of integers (up to @chunk_size) with a lazy tail; `end_` of
  # nil means unbounded. range_build returns `{next, elems}` where `next` is
  # the next start index, or nil when the range is exhausted.
  defp range_chunk(start, end_) do
    if end_ != nil and start >= end_ do
      nil
    else
      {elems, next} = range_build(start, end_, [], LazySeq.chunk_size())

      # An exhausted bounded range ends as a proper list, so a small
      # `(range n)` is a proper list rather than an improper tail.
      if is_nil(next),
        do: elems,
        else: LazySeq.chain(elems, fn -> range_chunk(next, end_) end)
    end
  end

  defp range_build(i, _end_, acc, 0), do: {Enum.reverse(acc), i}

  defp range_build(i, end_, acc, n) do
    if end_ != nil and i >= end_ do
      {Enum.reverse(acc), nil}
    else
      range_build(i + 1, end_, [i | acc], n - 1)
    end
  end

  @doc "`(iterate f x)` yields x, (f x), (f (f x)), … forever, lazily."
  def iterate(f, x), do: LazySeq.new(fn -> iterate_from(f, x) end)
  defp iterate_from(f, x), do: [x | LazySeq.new(fn -> iterate_from(f, invoke(f, [x])) end)]

  @doc "`(repeat x)` is infinite and lazy; `(repeat n x)` is a realized list."
  def repeat(x), do: LazySeq.new(fn -> repeat_from(x) end)
  def repeat(n, x) when is_integer(n) and n >= 0, do: List.duplicate(x, n)
  def repeat(n, x), do: List.duplicate(x, max(n, 0))

  defp repeat_from(x), do: [x | LazySeq.new(fn -> repeat_from(x) end)]

  @doc "`(cycle coll)` repeats `coll` forever, lazily."
  def cycle(coll) do
    case LazySeq.cell(coll) do
      nil -> nil
      cells -> LazySeq.new(fn -> cycle_from(cells, cells) end)
    end
  end

  defp cycle_from(nil, _orig), do: nil

  defp cycle_from([h | t], orig) do
    rest = if t == [], do: orig, else: t
    [h | LazySeq.new(fn -> cycle_from(rest, orig) end)]
  end

  @doc "`(concat & seqs)` — a lazy seq of every input, in order."
  def concat(seqs) when is_list(seqs) do
    LazySeq.new(fn -> concat_chunk(seqs) end)
  end

  # A chunk is drawn from ONE source seq (up to @chunk_size elements). It
  # does not cross into a later seq mid-chunk, so taking the head of a
  # concat of a realized head + a huge lazy tail never realizes the tail —
  # Clojure's concat advances seqs lazily too. Returns `:empty`, a proper
  # list (all consumed), or `{elems, rest_seqs}` for a lazy tail.
  defp concat_chunk(seqs) do
    case concat_pull(seqs, LazySeq.chunk_size(), []) do
      :empty -> nil
      {[], rest} -> concat_chunk(rest)
      {elems, []} -> elems
      {elems, rest} -> LazySeq.chain(elems, fn -> concat_chunk(rest) end)
    end
  end

  defp concat_pull([], _n, []), do: :empty
  defp concat_pull([], _n, acc), do: {Enum.reverse(acc), []}
  defp concat_pull(seqs, 0, acc), do: {Enum.reverse(acc), seqs}

  defp concat_pull([s | rest], n, acc) do
    case LazySeq.cell(s) do
      # An exhausted leading seq is dropped here; the next chunk continues
      # from the remaining seqs rather than pulling them in this one.
      nil -> {Enum.reverse(acc), rest}
      [h | t] -> concat_pull([t | rest], n - 1, [h | acc])
    end
  end

  @doc """
  `(map f)` with no collection -- the transducer arity.

  It lives here beside the collection arity rather than in the prelude for a
  reason worth recording: an earlier attempt added it by REBINDING `map` in
  `core.bl` and delegating back to a captured primitive. That worked in
  isolation and broke under the jank fidelity suite, because upstream's own
  `map` slice defines a `map` with no transducer arity, and a `defn` is
  visible past the namespace that made it. Defining the arity on the
  primitive keeps one implementation and nothing to shadow.
  """
  def map_xform(f) do
    fn rf ->
      multi_fn(%{
        0 => fn -> invoke(rf, []) end,
        1 => fn result -> invoke(rf, [result]) end,
        2 => fn result, input -> invoke(rf, [result, invoke(f, [input])]) end
      })
    end
  end

  @doc "`(filter pred)` with no collection -- the transducer arity."
  def filter_xform(pred) do
    fn rf ->
      multi_fn(%{
        0 => fn -> invoke(rf, []) end,
        1 => fn result -> invoke(rf, [result]) end,
        2 => fn result, input ->
          # Elixir's `if` already treats nil/false as falsey, which is exactly
          # beam-lisp's rule -- the same test `skip_filter/2` uses on the
          # collection path, so both arities agree on what "passes" means.
          if invoke(pred, [input]), do: invoke(rf, [result, input]), else: result
        end
      })
    end
  end

  @doc """
  Clojure `(take n)` transducer: a stateful reducing-fn wrapper that lets the
  first n inputs through and drops the rest. `n` is held in a volatile, the
  same mutable-until-persisted trick the vendored take-nth transducer uses,
  so `into`'s 3-arity and splitv-at resolve `(take n)` as an xform from core.
  The returned fn answers 0/1/2-arg reducing calls through `invoke`, so a
  beam-lisp `reduce`/`transduce` fold can drive it.
  """
  def take_xform(n) do
    fn rf ->
      nv = BeamLisp.Refs.volatile(n)

      # a reducing step must answer 0/1/2-arg calls, so it is a `multi_fn`
      # tag (a plain Elixir closure is fixed-arity and a 2-arg step call
      # would blow up with "arity 1 called with 2 arguments")
      multi_fn(%{
        0 => fn -> invoke(rf, []) end,
        1 => fn result -> invoke(rf, [result]) end,
        2 => fn result, input ->
          cur = BeamLisp.Refs.deref(nv)
          BeamLisp.Refs.vreset!(nv, cur - 1)
          if cur > 0, do: invoke(rf, [result, input]), else: result
        end
      })
    end
  end

  @doc "Clojure `take`: force minimally, return a realized list."
  def take(n, coll), do: take_loop(n, coll, []) |> empty_contract()

  defp take_loop(n, _coll, acc) when is_integer(n) and n <= 0, do: Enum.reverse(acc)

  defp take_loop(n, coll, acc) do
    case LazySeq.cell(coll) do
      nil -> Enum.reverse(acc)
      [h | t] -> take_loop(n - 1, t, [h | acc])
    end
  end

  def take_while(pred, coll), do: LazySeq.new(fn -> take_while_seg(pred, seqable(coll)) end)

  # Chunked: collect up to @chunk_size consecutive matches, stopping at the
  # first non-match (which ends the whole seq, so no tail is produced then).
  defp take_while_seg(pred, coll) do
    case take_while_build(pred, coll, [], LazySeq.chunk_size()) do
      :empty -> nil
      {elems, rest} when is_nil(rest) -> elems
      {elems, rest} -> LazySeq.chain(elems, fn -> take_while_seg(pred, rest) end)
    end
  end

  defp take_while_build(_pred, _coll, [], 0), do: :empty

  defp take_while_build(_pred, coll, acc, 0) do
    if acc == [], do: :empty, else: {Enum.reverse(acc), coll}
  end

  defp take_while_build(pred, coll, acc, n) do
    case LazySeq.cell(coll) do
      nil -> if acc == [], do: :empty, else: {Enum.reverse(acc), nil}

      [h | t] ->
        if invoke(pred, [h]) do
          take_while_build(pred, t, [h | acc], n - 1)
        else
          if acc == [], do: :empty, else: {Enum.reverse(acc), nil}
        end
    end
  end

  def drop_while(pred, coll), do: LazySeq.new(fn -> drop_while_skip(pred, seqable(coll)) end)

  defp drop_while_skip(pred, coll) do
    case LazySeq.cell(coll) do
      nil -> nil
      [h | t] -> if invoke(pred, [h]), do: drop_while_skip(pred, t), else: [h | t]
    end
  end

  @doc """
  `(doall coll)` fully realizes a lazy seq, returning it. A
  partially-realized improper list (`[h | LazySeq]` — what cons onto a
  lazy tail yields) is realized to a proper list too, so a lazy
  interleave / interpose result survives doall and the printer; a proper
  list is returned unchanged.
  """
  def doall(%LazySeq{} = l), do: LazySeq.to_list(l)
  def doall(coll) when is_list(coll), do: if(improper?(coll), do: LazySeq.to_list(coll), else: coll)
  def doall(coll), do: coll

  # An "improper" list is a cons chain that terminates in a LazySeq
  # rather than `[]` — the beam-lisp shape for a partially-realized seq
  # (`cons x lazy`). `LazySeq.to_list` and `LazySeq.sample` already walk
  # these via cell/1, but plain Enum calls (and the is_list print branch)
  # assume a proper list, so callers that must handle both check here.
  defp improper?([_ | t]), do: improper_tail?(t)
  defp improper?(_), do: false
  defp improper_tail?(nil), do: false
  defp improper_tail?([]), do: false
  defp improper_tail?(%LazySeq{}), do: true
  defp improper_tail?([_ | t]), do: improper_tail?(t)

  @doc "`(dorun coll)` forces a lazy seq for side effects, returning nil."
  def dorun(%LazySeq{} = l) do
    LazySeq.run(l)
    nil
  end

  def dorun(_coll), do: nil

  @doc "Clojure `assoc`: maps get a key update, vectors an index update (append at count)."
  def assoc(coll, k, v)
  def assoc(%BeamLisp.Vector{} = v, i, x), do: BeamLisp.Vector.assoc(v, i, x)
  # A set is a struct (and so a map) — this must precede the map
  # clause or assoc would silently add a field to the struct. Clojure
  # raises; fail loudly instead of corrupting the set's shape.
  def assoc(%Set{}, _k, _v),
    do: raise(ArgumentError, "assoc not supported on a set")

  # A sorted map assoc's like a map (order maintained by the tree); a
  # sorted set raises exactly as a hashed set does.
  def assoc(%SortedMap{} = m, k, v), do: Sorted.map_put(m, k, v)

  def assoc(%SortedSet{}, _k, _v),
    do: raise(ArgumentError, "assoc not supported on a sorted set")
  # A reference is not a map — assoc'ing it would add a field to the struct.
  def assoc(%{__struct__: mod} = m, _k, _v) when is_atom(mod) and is_ref_type(m),
    do: raise(ArgumentError, "assoc: #{inspect(mod)} is a reference, not a collection")
  # A record's `__struct__` key is internal; assoc'ing it would silently
  # turn the record into a corrupted plain map, so fail loudly instead.
  def assoc(%{__struct__: mod} = m, k, v) when is_atom(mod) and k == :__struct__ do
    if BeamLisp.Record.record?(m),
      do: raise(ArgumentError, "assoc on the internal :__struct__ key is not allowed on a record"),
      else: Map.put(m, k, v)
  end
  # A record assoc's its public fields, preserving its type. Any other
  # struct reaching here (a LazySeq is the one the earlier clauses do not
  # own) is not a map and must raise — Map.put would silently grow a
  # struct with an extra field, corrupting its shape.
  def assoc(%{__struct__: mod} = m, k, v) when is_atom(mod) do
    if BeamLisp.Record.record?(m),
      do: Map.put(m, k, v),
      else: raise(ArgumentError, "assoc not supported on a struct")
  end
  def assoc(coll, k, v) when is_bl_map(coll), do: Map.put(coll, hash_key(k), v)
  def assoc(nil, k, v), do: Map.put(%{}, hash_key(k), v)

  @doc "Variadic `(assoc coll k v k2 v2 …)`."
  def assoc_variadic(coll, k, v, rest) when is_list(rest) do
    if rem(length(rest), 2) != 0 do
      raise ArgumentError, "assoc expects an even number of key/value arguments"
    end

    Enum.chunk_every(rest, 2)
    |> Enum.reduce(assoc(coll, k, v), fn [k2, v2], acc -> assoc(acc, k2, v2) end)
  end

  def even?(x), do: rem(x, 2) == 0
  def odd?(x), do: rem(x, 2) != 0
  def zero?(x), do: x == 0
  def pos?(x), do: x > 0
  def neg?(x), do: x < 0

  def print_str(%BeamLisp.Vector{} = v) do
    "[" <> Enum.map_join(BeamLisp.Vector.to_list(v), " ", &print_elem/1) <> "]"
  end

  def print_str({:"$blfn", _, nil}), do: "#fn[multi-arity]"
  def print_str({:"$blfn", _, _}), do: "#fn[variadic]"
  def print_str({:"$remote", m, f}), do: "#fn[#{m}/#{f}]"
  def print_str(x) when is_binary(x), do: x
  def print_str({:symbol, name}), do: name
  def print_str(nil), do: "nil"
  def print_str(true), do: "true"
  def print_str(false), do: "false"
  def print_str(x) when is_atom(x), do: ":" <> Atom.to_string(x)
  # A proper list prints fully; an improper one (a partially-realized
  # seq whose tail is a LazySeq) goes through the bounded sample path so
  # an infinite lazy interleave can never hang the printer.
  def print_str(x) when is_list(x) do
    if improper?(x), do: print_seq(x), else: "(" <> Enum.map_join(x, " ", &print_elem/1) <> ")"
  end

  def print_str(%LazySeq{} = l), do: print_seq(l)

  # A set prints as `#{…}`. The `"#" <> "{"` splice avoids the `#{`
  # Elixir-interpolation pitfall. (A set is a struct-map, so this must
  # precede the is_bl_map clause.)
  def print_str(%Set{} = s) do
    body = s |> Set.to_list() |> Enum.map_join(" ", &print_elem/1)
    "#" <> "{" <> body <> "}"
  end

  # Ordered collections print like their hashed siblings — the ORDER is the
  # visible difference, and it is deterministic, which is what makes these
  # printable forms usable in test assertions.
  def print_str(%SortedSet{} = s) do
    body = s |> Sorted.set_to_list() |> Enum.map_join(" ", &print_elem/1)
    "#" <> "{" <> body <> "}"
  end

  def print_str(%SortedMap{} = m) do
    body =
      m
      |> Sorted.map_to_list()
      |> Enum.map_join(", ", fn {k, v} -> print_elem(k) <> " " <> print_elem(v) end)

    "{" <> body <> "}"
  end

  # A record prints readably as `#ns/Name{field val …}` — the tagged
  # literal form the reader lowers back into a record, so `pr-str` then
  # read round-trips to an equal record (a plain map print would come
  # back as a map, breaking record equality). The `"#" <>` splice avoids
  # the `#{` Elixir-interpolation pitfall.
  # A reference is not a map — printing it as a map would leak its backing
  # process (`{:pid #PID…}`); print it via inspect instead.
  def print_str(%{__struct__: mod} = r) when is_atom(mod) and is_ref_type(r), do: inspect(r)

  def print_str(%{__struct__: mod} = r) when is_atom(mod) do
    if BeamLisp.Record.record?(r) do
      {_, ns, name, _} = BeamLisp.Record.info(mod)

      body =
        r
        |> Map.to_list()
        |> Enum.reject(fn {k, _} -> k == :__struct__ end)
        |> Enum.map_join(", ", fn {k, v} -> print_elem(k) <> " " <> print_elem(v) end)

      "#" <> ns <> "/" <> name <> "{" <> body <> "}"
    else
      print_str_map(r)
    end
  end

  def print_str(m) when is_bl_map(m), do: print_str_map(m)

  def print_str(x), do: inspect(x)

  # Bounded printing for a lazy or improper seq: realize at most 20
  # elements and truncate with " …" if more remain, so an infinite seq
  # can never hang the printer. Shared by LazySeq and improper-list
  # print_str clauses.
  defp print_seq(seq) do
    {elems, truncated} = LazySeq.sample(seq, 20)
    body = Enum.map_join(elems, " ", &print_elem/1)
    suffix = if truncated, do: " …", else: ""
    "(" <> body <> suffix <> ")"
  end

  defp print_str_map(m) do
    pairs = Enum.map_join(m, ", ", fn {k, v} -> print_elem(k) <> " " <> print_elem(v) end)
    "{" <> pairs <> "}"
  end

  # `(println)` with no arguments prints a blank line, as Clojure's does --
  # it is how you space output, and an example that has to write
  # `(println "")` instead reads like a workaround for a missing arity.
  def println, do: IO.puts("")
  def println(x), do: IO.puts(print_str(x))

  # Clojure's println is variadic and space-separates its arguments, so
  # `(println "count:" n)` reads the way it looks. Without it every
  # caller reaches for `(println (str "count: " n))`, which is the same
  # thing said less well --- and an example full of that spelling reads
  # like a workaround for a missing arity, because it is one.
  def println_multi(x, rest_list) when is_list(rest_list) do
    IO.puts(Enum.map_join([x | rest_list], " ", &print_str/1))
  end

  # The reader-macro table: dispatch-char → wrapper symbol name.
  # Lives in the vars ETS table (same registry as vars); the reader
  # consults it for `@`, core.bl registers the mapping, users may
  # rebind it. `(reader-macro! "@" (quote deref))`.
  def reader_macro(char) do
    case BeamLisp.Env.lookup({:reader_macro, char}) do
      {:ok, name} -> {:ok, name}
      :error -> :error
    end
  end

  def reader_macro!(char, {:symbol, name}) when is_binary(char) do
    BeamLisp.Env.put_key({:reader_macro, char}, name)
    name
  end

  @doc """
  A registered data-reader for the `#tag[...]` / `#tag{...}` literal, or
  `:error`. Mirrors `reader_macro/1` but keyed by a TAG NAME rather than a
  single dispatch char, so `#d[…]` looks up the symbol `d`. The reader
  wraps the following collection as `(<fn-symbol> <collection>)`, exactly
  as Clojure's `*data-readers*` expands `#inst "…"`.
  """
  def data_reader(tag) when is_binary(tag) do
    case BeamLisp.Env.lookup({:data_reader, tag}) do
      {:ok, name} -> {:ok, name}
      :error -> data_reader_default(tag)
    end
  end

  # Builtin data-reader defaults, mirroring the `@`→`deref` fallback in the
  # reader: a whole file is READ before any form (including the `data-reader!`
  # registration in `priv/datom.bl`) EVALUATES, so a `#d[…]` literal in a file
  # that merely `:require`s datom would not see a purely runtime registration.
  # Naming the builtin here keeps `#d[…]` readable from first boot; a runtime
  # `data-reader!` still overrides it (checked first, above).
  defp data_reader_default("d"), do: {:ok, {:symbol, "datom/read-query"}}
  defp data_reader_default(_), do: :error

  @doc """
  `(data-reader! "d" 'datom/read-query)` registers a data-reader so
  `#d[…]` reads as `(datom/read-query […])`. Rebindable, like
  `reader-macro!`, and registered from beam-lisp source rather than wired
  into the reader.
  """
  def data_reader!(tag, {:symbol, name}) when is_binary(tag) do
    BeamLisp.Env.put_key({:data_reader, tag}, name)
    name
  end

  @doc """
  `(read-data s)` — read ONE form of source as DATA. Never evaluates.

  This is the seam a model-written definition crosses (`spell.run`): source
  arrives as text, and the only safe thing to do with text is READ it — the
  reader's atom guard (PLAN-009) bounds what reading can intern, and no form
  is ever compiled or called. Errors raise SyntaxError, which the ladder
  catches and reports as a rung-1 refusal.
  """
  def read_data(source) when is_binary(source), do: BeamLisp.Compiler.read_data(source)

  # Inside a collection, strings print readably; at the top level
  # (println, pr-str of a bare string) they print raw.
  defp print_elem(x) when is_binary(x), do: inspect(x)
  defp print_elem(x), do: print_str(x)

  @doc false
  def str do
    multi_fn(%{}, {0, fn args -> Enum.map_join(args, "", &to_str/1) end})
  end

  # `(= a b c)` is a chain: eqv(a, b) and eqv(b, c). Same shape as the
  # comparison chains, but with lazy-aware equality.
  defp eqv_chain do
    multi_fn(%{}, {1, fn x, rest ->
      [x | rest]
      |> Enum.zip(rest)
      |> Enum.all?(fn {a, b} -> eqv(a, b) end)
    end})
  end

  defp to_str(nil), do: ""
  defp to_str(x) when is_binary(x), do: x
  defp to_str(x) when is_atom(x), do: Atom.to_string(x)
  # A symbol stringifies to its name — `(str 'foo)` is "foo", which
  # jank's keyword ctor needs (`(cpp/jank.runtime.keyword nil (str name))`).
  defp to_str({:symbol, name}), do: name
  # Clojure's `str` falls back to the printed representation, so
  # `(str {:a 1})` is "{:a 1}" rather than a String.Chars crash. Maps,
  # vectors, lists and lazy seqs have no String.Chars impl on the BEAM,
  # and `print_str/1` is exactly the printer that knows their syntax.
  # is_map-ok: str's fallback must reach print_str for records too (they
  # have no String.Chars), and print_str already routes references away
  # from the map path — this only selects the printer, not a collection op.
  defp to_str(x) when is_map(x) or is_list(x) or is_tuple(x), do: print_str(x)
  defp to_str(x), do: to_string(x)

  # Fresh, collision-proof symbol datum for hand-written macros. Shares
  # the `__N__auto` shape with syntax-quote `x#` auto-gensyms.
  def gensym(), do: gensym("G")

  def gensym(prefix) when is_binary(prefix) do
    {:symbol,
     prefix <> "__" <> Integer.to_string(System.unique_integer([:positive])) <> "__auto"}
  end

  # `trace`/`untrace` resolve a quoted symbol against the namespace the
  # call runs in; the registered prim arities match the beam-lisp surface
  # and thread `Env.current_ns/0` in here.
  defp trace_2(sym, handler), do: BeamLisp.Trace.trace(Env.current_ns(), sym, handler)

  defp trace_3(sym, handler, opts),
    do: BeamLisp.Trace.trace(Env.current_ns(), sym, handler, opts)

  defp untrace_1(sym), do: BeamLisp.Trace.untrace(Env.current_ns(), sym)

  @doc "Seed `core` with the primitives the prelude and interop need."
  def seed_core do
    # Clojure arithmetic is variadic: (+ 1 2 3), (*) → 1, (- 5) → -5.
    arith = %{
      "+" => multi_fn(%{}, {0, fn args -> Enum.reduce(args, 0, &Kernel.+/2) end}),
      "*" => multi_fn(%{}, {0, fn args -> Enum.reduce(args, 1, &Kernel.*/2) end}),
      "-" => multi_fn(%{}, {1, fn x, rest ->
        case rest do
          [] -> -x
          _ -> Enum.reduce(rest, x, fn e, acc -> Kernel.-(acc, e) end)
        end
      end}),
      "/" => multi_fn(%{}, {1, fn x, rest ->
        case rest do
          [] -> 1 / x
          _ -> Enum.reduce(rest, x, fn e, acc -> Kernel./(acc, e) end)
        end
      end})
    }

    # (< 1 2 3) is a chain: 1 < 2 and 2 < 3.
    chain = fn op ->
      multi_fn(%{}, {1, fn x, rest ->
        [x | rest]
        |> Enum.zip(rest)
        |> Enum.all?(fn {a, b} -> op.(a, b) end)
      end})
    end

    prims = Map.merge(arith, %{
      "<" => chain.(&Kernel.</2),
      ">" => chain.(&Kernel.>/2),
      "<=" => chain.(&Kernel.<=/2),
      ">=" => chain.(&Kernel.>=/2),
      "=" => eqv_chain(),
      "not" => &not_/1,
      "identical?" => &identical?/2,
      "str" => str(),
      "first" => &first/1,
      "rest" => &rest/1,
      "seq" => &seq/1,
      "cons" => &cons/2,
      "conj" => multi_fn(%{1 => &conj/1, 2 => &conj/2}),
      "count" => &count/1,
      "nth" => multi_fn(%{2 => &nth/2, 3 => &nth/3}),
      "empty?" => &empty?/1,
      "get" => multi_fn(%{2 => &get/2, 3 => &get/3}),
      "assoc" => multi_fn(%{3 => &assoc/3}, {3, &assoc_variadic/4}),
      "apply" => multi_fn(%{2 => &apply_to/2}, {2, &apply_variadic/3}),
      "next" => &next/1,
      "list*" => multi_fn(%{0 => &list_star_0/0}, {1, &list_star/2}),
      "println" => multi_fn(%{0 => &println/0, 1 => &println/1}, {1, &println_multi/2}),
      "pr-str" => &print_str/1,
      # Clojure's `print-str` returns the printed representation (like
      # pr-str, minus readably-quoted strings); both share the one printer.
      "print-str" => &print_str/1,
      "gensym" => multi_fn(%{0 => &gensym/0, 1 => &gensym/1}),
      # lazy sequences: uniformly lazy (chunked at 32), realized only by
      # forcing consumers (take/reduce/count/doall/…).
      # `map` is variadic: the 2-arity is the chunked lazy path, 3+ colls stop at the shortest.
      "map" => multi_fn(%{1 => &map_xform/1, 2 => &map/2}, {2, &map_multi/3}),
      "filter" => multi_fn(%{1 => &filter_xform/1, 2 => &filter/2}),
      "range" => multi_fn(%{0 => &range/0, 1 => &range/1, 2 => &range/2}),
      "iterate" => &iterate/2,
      "repeat" => multi_fn(%{1 => &repeat/1, 2 => &repeat/2}),
      "cycle" => &cycle/1,
      "concat" => multi_fn(%{}, {0, fn args -> concat(args) end}),
      "take" => multi_fn(%{1 => &take_xform/1, 2 => &take/2}),
      "drop" => &drop_clj/2,
      "take-while" => &take_while/2,
      "drop-while" => &drop_while/2,
      "doall" => &doall/1,
      "dorun" => &dorun/1,
      # numeric / collection predicates
      "even?" => &even?/1,
      "odd?" => &odd?/1,
      "zero?" => &zero?/1,
      "pos?" => &pos?/1,
      "neg?" => &neg?/1,
      "rem" => &rem/2,
      "float?" => &float?/1,
      "transientable?" => &transientable?/1,
      # type & collection predicates (wave 14)
      "fn?" => &fn?/1,
      "seq?" => &seq?/1,
      "boolean" => &boolean/1,
      "find" => &find/2,
      "contains?" => &contains?/2,
      "keyword?" => &keyword?/1,
      "symbol?" => &symbol?/1,
      "string?" => &string?/1,
      "number?" => &number?/1,
      "int?" => &int?/1,
      "map?" => &map?/1,
      "struct?" => &struct?/1,
      "associative?" => &associative?/1,
      "vector?" => &vector?/1,
      "list?" => &list?/1,
      "coll?" => &coll?/1,
      "ident?" => &ident?/1,
      # sets (wave 18)
      "set" => &set/1,
      # Ordered collections. The variadic surface (sorted-map, sorted-set)
      # is defined in priv/core.bl over these; what lands here is only
      # what needs :gb_trees underneath.
      "sorted-map-of" => &sorted_map_of/1,
      "sorted-set-of" => &sorted_set_of/1,
      "sorted?" => &sorted?/1,
      "last-key" => &last_key/1,
      "last-entry" => &last_entry/1,
      "subseq" => &subseq/3,
      "rsubseq" => &rsubseq/3,
      "sorted-map?" => &sorted_map?/1,
      "sorted-set?" => &sorted_set?/1,
      "sorted-dissoc" => &sorted_dissoc/2,
      "set?" => &set?/1,
      "disj" => &disj/2,
      "sequential?" => &sequential?/1,
      "tree-seq" => &tree_seq/3,
      # sort / compare (wave 18)
      "compare" => &compare/2,
      "sort" => multi_fn(%{1 => &sort/1, 2 => &sort/2})
    })

    # Reference types: atoms, futures, promises. All plain Refs
    # fns, so the link entries below turn call sites into direct
    # remote calls.
    refs_prims = %{
      "atom" => &BeamLisp.Refs.atom/1,
      "deref" => multi_fn(%{1 => &BeamLisp.Refs.deref/1, 3 => &BeamLisp.Refs.deref/3}),
      "swap!" => multi_fn(%{2 => &BeamLisp.Refs.swap!/2}, {2, &BeamLisp.Refs.swap!/3}),
      "reset!" => &BeamLisp.Refs.reset!/2,
      "compare-and-set!" => &BeamLisp.Refs.compare_and_set!/3,
      # Clojure names these without the bang; keep the Clojure spelling so
      # `(add-watch a :k f)` reads the same here as it does there.
      "add-watch" => &BeamLisp.Refs.add_watch!/3,
      "remove-watch" => &BeamLisp.Refs.remove_watch!/2,
      "promise" => &BeamLisp.Refs.promise/0,
      "deliver" => &BeamLisp.Refs.deliver/2,
      "future?" => &BeamLisp.Refs.future?/1,
      "future-cancel" => &BeamLisp.Refs.future_cancel/1,
      "volatile!" => &BeamLisp.Refs.volatile/1,
      "vreset!" => &BeamLisp.Refs.vreset!/2,
      "vswap!" => multi_fn(%{2 => &BeamLisp.Refs.vswap!/2}, {2, &BeamLisp.Refs.vswap!/3}),
      "volatile?" => &BeamLisp.Refs.volatile?/1,
      "reduced" => &reduced/1,
      "reduced?" => &reduced?/1,
      "reader-macro!" => &reader_macro!/2,
      "data-reader!" => &data_reader!/2,
      "read-data" => &read_data/1
    }

    prims = Map.merge(prims, refs_prims)

    # Transients: mutable-until-persisted views of vectors and maps.
    # Fixed arities are plain fns; hash-map is variadic (even forms).
    transient_prims = %{
      "transient" => &BeamLisp.Transient.transient/1,
      "persistent!" => &BeamLisp.Transient.persistent!/1,
      "conj!" =>
        multi_fn(%{1 => &BeamLisp.Transient.conj!/1, 2 => &BeamLisp.Transient.conj!/2}),
      "assoc!" => &BeamLisp.Transient.assoc!/3,
      "dissoc!" => &BeamLisp.Transient.dissoc!/2,
      "hash-map" =>
        multi_fn(%{0 => &BeamLisp.Transient.hash_map_empty/0},
                 {2, &BeamLisp.Transient.hash_map/3})
    }

    prims = Map.merge(prims, transient_prims)

    # Wave 22: the BEAM-native band. `supervise`/`worker` lower a
    # supervision tree to a real Elixir Supervisor (see BeamLisp.Supervisor);
    # `trace`/`untrace` expose `:dbg` as data with hard safety rails (see
    # BeamLisp.Trace). The trace wrappers thread the current namespace in,
    # since a quoted symbol resolves against the defining ns.
    otp_prims = %{
      "supervise" =>
        multi_fn(%{
          2 => &BeamLisp.Supervisor.supervise/2,
          3 => &BeamLisp.Supervisor.supervise/3
        }),
      "worker" =>
        multi_fn(%{
          2 => &BeamLisp.Supervisor.worker/2,
          3 => &BeamLisp.Supervisor.worker/3
        }),
      "trace" => multi_fn(%{2 => &trace_2/2, 3 => &trace_3/3}),
      "untrace" => &untrace_1/1,
      # The client side of `defserver`. Without these a server is only
      # reachable through raw `:gen_server` interop, which defeats the
      # point of the form. Names are prefixed `server-` because `call`
      # and `cast` are far too generic to claim in the core namespace.
      "server-start-link" =>
        multi_fn(%{
          1 => &BeamLisp.Server.start_link/1,
          2 => &BeamLisp.Server.start_link/2,
          3 => &BeamLisp.Server.start_link/3
        }),
      "server-start" =>
        multi_fn(%{
          1 => &BeamLisp.Server.start/1,
          2 => &BeamLisp.Server.start/2,
          3 => &BeamLisp.Server.start/3
        }),
      "server-call" =>
        multi_fn(%{2 => &BeamLisp.Server.call/2, 3 => &BeamLisp.Server.call/3}),
      "server-cast" => &BeamLisp.Server.cast/2,
      "server-stop" =>
        multi_fn(%{1 => &BeamLisp.Server.stop/1, 2 => &BeamLisp.Server.stop/2})
    }

    prims = Map.merge(prims, otp_prims)
    Enum.each(prims, fn {name, f} -> Env.intern("core", name, f) end)

    # cpp/* interop: jank calls its C++ primitives under the `cpp`
    # namespace (`(cpp/jank.runtime.name x)`). beam-lisp maps that
    # qualified name onto a BEAM function with the same semantics, so
    # upstream core.jank slices load and call unchanged — no fixture
    # edit, the resolution target namespace just happens to be `cpp`.
    cpp_prims = %{
      "jank.runtime.name" => &name_of/1,
      "jank.runtime.namespace_" => &namespace_of/1,
      "jank.runtime.keyword" => &keyword_of/2,
      # The reduce/transducer core and the numeric layer. `reduce` is
      # honest: it actually short-circuits on a Reduced, and the is_*
      # predicates report beam-lisp's real type space (no Ratio and no
      # BigDecimal, so those are genuinely always false; `is_sorted` was
      # in that list until PLAN-033 wave 1 gave the language real ordered
      # collections, and it now answers truthfully for them).
      "jank.runtime.reduce" => &reduce/3,
      "jank.runtime.reduced" => &reduced/1,
      "jank.runtime.is_reduced" => &reduced?/1,
      "jank.runtime.peek" => &peek/1,
      "jank.runtime.pop" => &pop/1,
      "jank.runtime.promoting_inc" => &promoting_inc/1,
      "jank.runtime.is_integer" => &int?/1,
      "jank.runtime.is_ratio" => &ratio?/1,
      "jank.runtime.is_big_decimal" => &decimal?/1,
      "jank.runtime.is_sorted" => &sorted?/1,
      "jank.runtime.is_nan" => &nan?/1,
      "jank.runtime.is_list" => &list?/1,
      "jank.runtime.volatile_" => &BeamLisp.Refs.volatile/1,
      "jank.runtime.vreset" => &BeamLisp.Refs.vreset!/2,
      "jank.runtime.vswap" =>
        multi_fn(%{2 => &BeamLisp.Refs.vswap!/2, 3 => &BeamLisp.Refs.vswap!/3}),
      "jank.runtime.is_volatile" => &BeamLisp.Refs.volatile?/1,
      # bit-not's inline expands to a call to this (slice_78); the reader
      # gate was clear, only the table row was missing.
      "jank.runtime.bit_not" => &bit_not/1
    }

    Enum.each(cpp_prims, fn {name, f} -> Env.intern("cpp", name, f) end)
    seed_links()
    :ok
  end

  # Prims link to direct calls too: operators to their :erlang BIFs,
  # seq fns to BeamLisp.RT. Only arities whose semantics match
  # exactly get linked — everything else falls back to invoke.
  defp seed_links do
    # beam-lisp name -> the Erlang BIF that implements it. Most spell
    # the same, but Erlang writes `=<` where Clojure writes `<=`, so a
    # name-is-the-BIF assumption silently linked `<=` to a function
    # that does not exist: `(<= 1 2)` raised :erlang.<=/2 undefined
    # while the chained `(<= 1 2 3)` went through invoke and worked.
    bif2 = [{"+", :+}, {"-", :-}, {"*", :*}, {"/", :/}, {"<", :<}, {">", :>},
            {"<=", :"=<"}, {">=", :>=}, {"==", :==},
            {"rem", :rem}]

    for {name, op} <- bif2 do
      Env.put_link("core", name, {:erlang, %{2 => op}, nil})
    end

    # Unary + - * are identity/negate on the BIFs; (= x) and friends
    # stay invoke (chain semantics).
    Env.put_link("core", "+", {:erlang, %{1 => :+, 2 => :+}, nil})
    Env.put_link("core", "-", {:erlang, %{1 => :-, 2 => :-}, nil})
    Env.put_link("core", "*", {:erlang, %{1 => :*, 2 => :*}, nil})
    # `=` links to lazy-aware equality (realizes lazy operands) so
    # comparing a lazy seq stays Clojure-shaped.
    Env.put_link("core", "=", {BeamLisp.RT, %{2 => :eqv}, nil})

    rt_fns = %{
      "first" => 1,
      "rest" => 1,
      "seq" => 1,
      "cons" => 2,
      "count" => 1,
      "nth" => 2,
      "empty?" => 1,
      "next" => 1,
      "pr-str" => :print_str,
      "print-str" => :print_str,
      "reader-macro!" => :reader_macro!,
      "data-reader!" => :data_reader!,
      "read-data" => :read_data,
      "assoc" => 3,
      # (`filter` is deliberately absent: it grew a 1-arity transducer form, and
      # this table links a single fixed arity. `take` is absent for the same
      # reason. A multi-arity prim resolves through `invoke`, which reads the
      # multi_fn tag -- linking one arity here would make the other unreachable.)
      "take-while" => :take_while,
      "drop-while" => :drop_while,
      "iterate" => 2,
      "cycle" => 1,
      "doall" => 1,
      "dorun" => 1,
      "even?" => 1,
      "odd?" => 1,
      "zero?" => 1,
      "pos?" => 1,
      "neg?" => 1,
      "float?" => 1,
      "transientable?" => 1,
      "fn?" => 1,
      "seq?" => 1,
      "boolean" => 1,
      "find" => 2,
      "contains?" => 2,
      "keyword?" => 1,
      "symbol?" => 1,
      "string?" => 1,
      "number?" => 1,
      "int?" => 1,
      "map?" => 1,
      "struct?" => 1,
      "associative?" => 1,
      "vector?" => 1,
      "list?" => 1,
      "coll?" => 1,
      "ident?" => 1,
      "set" => 1,
      "sorted?" => 1,
      "subseq" => 3,
      "rsubseq" => 3,
      "set?" => 1,
      "disj" => 2,
      "sequential?" => 1,
      "compare" => 2,
      "identical?" => 2
    }

    for {name, spec} <- rt_fns do
      {fname, arity} =
        case spec do
          a when is_atom(a) -> {a, 2}
          n when is_integer(n) -> {String.to_atom(name), n}
        end

      Env.put_link("core", name, {BeamLisp.RT, %{arity => fname}, nil})
    end

    # `sort` is multi-arity: both the comparator-less and comparator
    # forms link directly to the same fn name (arity splits the call).
    Env.put_link("core", "sort", {BeamLisp.RT, %{1 => :sort, 2 => :sort}, nil})

    # `tree-seq` is 3-arity and dash-named; the integer-spec loop would
    # mangle it to `:"tree-seq"`, so link it explicitly (the prelude
    # loop maps dashed names only for 2-arity fns).
    Env.put_link("core", "tree-seq", {BeamLisp.RT, %{3 => :tree_seq}, nil})

    # The dash-named sorted prims have the same problem as `tree-seq`: the
    # integer-spec loop above would mangle `sorted-map-of` into the atom
    # `:"sorted-map-of"`, which is not the fn's name. Link them explicitly
    # to their underscored definitions. (Symptom when missed: a call raises
    # `function BeamLisp.RT."sorted-map-of"/1 is undefined` at RUNTIME, not
    # at compile time — the link table is only consulted on invocation.)
    Env.put_link("core", "sorted-map-of", {BeamLisp.RT, %{1 => :sorted_map_of}, nil})
    Env.put_link("core", "sorted-set-of", {BeamLisp.RT, %{1 => :sorted_set_of}, nil})
    Env.put_link("core", "last-key", {BeamLisp.RT, %{1 => :last_key}, nil})
    Env.put_link("core", "last-entry", {BeamLisp.RT, %{1 => :last_entry}, nil})
    Env.put_link("core", "sorted-map?", {BeamLisp.RT, %{1 => :sorted_map?}, nil})
    Env.put_link("core", "sorted-set?", {BeamLisp.RT, %{1 => :sorted_set?}, nil})
    Env.put_link("core", "sorted-dissoc", {BeamLisp.RT, %{2 => :sorted_dissoc}, nil})

    # gensym links both arities directly — plain name, no mangling.
    Env.put_link("core", "gensym", {BeamLisp.RT, %{0 => :gensym, 1 => :gensym}, nil})

    # `get` fixes its 2-arity fallback (which `RT.invoke` needs when a
    # 2-arg call misses the old 3-arity link) and keeps the 3-arity fast
    # path. `drop` is Clojure-ordered (`(drop n coll)`) via `drop_clj`.
    Env.put_link("core", "get", {BeamLisp.RT, %{2 => :get, 3 => :get}, nil})

    # `nth` links both arities: the 3-arity carries Clojure's `not-found`, which
    # is what lets a caller distinguish an out-of-range index from an element
    # that is legitimately nil.
    Env.put_link("core", "nth", {BeamLisp.RT, %{2 => :nth, 3 => :nth}, nil})
    Env.put_link("core", "drop", {BeamLisp.RT, %{2 => :drop_clj}, nil})

    # `map` links its fixed 2-arity to the chunked lazy path and routes 3+
    # colls to the multi-coll lazy handler (stops at the shortest input). `take`
    # gains its 1-arity transducer (used by `into`/splitv-at) alongside the
    # existing 2-arity coll form.
    Env.put_link("core", "map", {BeamLisp.RT, %{2 => :map}, {2, :map_multi}})
    Env.put_link("core", "take", {BeamLisp.RT, %{1 => :take_xform, 2 => :take}, nil})
    # `conj` links its completion arity (1) beside the value arity (2).
    Env.put_link("core", "conj", {BeamLisp.RT, %{1 => :conj, 2 => :conj}, nil})

    # `apply` and `list*` are multi-arity prims: the 2-arity `apply` links
    # directly, higher arities split into fixed leading args + one rest list
    # for the variadic handler. `list*` keeps its 0-arity (`(list*)` → nil).
    Env.put_link("core", "apply", {BeamLisp.RT, %{2 => :apply_to}, {2, :apply_variadic}})
    Env.put_link("core", "list*", {BeamLisp.RT, %{0 => :list_star_0}, {1, :list_star}})

    # Multi-arity lazy constructors.
    Env.put_link("core", "range", {BeamLisp.RT, %{0 => :range, 1 => :range, 2 => :range}, nil})
    Env.put_link("core", "repeat", {BeamLisp.RT, %{1 => :repeat, 2 => :repeat}, nil})

    # Reference types link to direct calls too. The trailing `!`
    # atoms are valid Elixir; "compare-and-set!" mangles to
    # `:compare_and_set!`.
    ref_links = %{
      "atom" => {BeamLisp.Refs, %{1 => :atom}, nil},
      "deref" => {BeamLisp.Refs, %{1 => :deref, 3 => :deref}, nil},
      "swap!" => {BeamLisp.Refs, %{2 => :swap!}, {2, :swap!}},
      "reset!" => {BeamLisp.Refs, %{2 => :reset!}, nil},
      "compare-and-set!" => {BeamLisp.Refs, %{3 => :compare_and_set!}, nil},
      "add-watch" => {BeamLisp.Refs, %{3 => :add_watch!}, nil},
      "remove-watch" => {BeamLisp.Refs, %{2 => :remove_watch!}, nil},
      "promise" => {BeamLisp.Refs, %{0 => :promise}, nil},
      "deliver" => {BeamLisp.Refs, %{2 => :deliver}, nil},
      "future?" => {BeamLisp.Refs, %{1 => :future?}, nil},
      "future-cancel" => {BeamLisp.Refs, %{1 => :future_cancel}, nil}
    }

    for {name, info} <- ref_links do
      Env.put_link("core", name, info)
    end

    # Transients link to direct calls too. The `!` names are valid
    # Elixir atoms (like swap!/reset!); hash-map's variadic splits into
    # 2 fixed args + a rest list against the mangled `hash_map/3`.
    transient_links = %{
      "transient" => {BeamLisp.Transient, %{1 => :transient}, nil},
      "persistent!" => {BeamLisp.Transient, %{1 => :persistent!}, nil},
      "conj!" => {BeamLisp.Transient, %{1 => :conj!, 2 => :conj!}, nil},
      "assoc!" => {BeamLisp.Transient, %{3 => :assoc!}, nil},
      "dissoc!" => {BeamLisp.Transient, %{2 => :dissoc!}, nil},
      "hash-map" => {BeamLisp.Transient, %{0 => :hash_map_empty}, {2, :hash_map}}
    }

    for {name, info} <- transient_links do
      Env.put_link("core", name, info)
    end

    :ok
  end
end
