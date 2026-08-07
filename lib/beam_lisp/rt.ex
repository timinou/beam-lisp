defmodule BeamLisp.RT do
  @moduledoc """
  Runtime primitives seeded into the `core` namespace before any
  beam-lisp code runs. Everything here is an ordinary Elixir function
  value, so compiled beam-lisp code calls them with plain `apply/2`.
  """

  alias BeamLisp.{Env, LazySeq, Set}

  @multi_fn_tag :"$blfn"

  @doc "Wraps arity-dispatched clauses; Elixir fns are fixed-arity, so multi-arity and variadic beam-lisp fns need a tag."
  def multi_fn(clauses) when is_map(clauses), do: {@multi_fn_tag, clauses, nil}
  def multi_fn(clauses, {min, f}) when is_map(clauses), do: {@multi_fn_tag, clauses, {min, f}}

  @doc false
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
  def invoke({:"$remote", module, fun}, args), do: apply(module, fun, args)

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

  # A record is a struct (and so a map), but its `__struct__` key is
  # internal — field access goes through the public fields only, so
  # `(:__struct__ p)` is nil, not the module.
  def get(%{__struct__: mod} = m, key, default) when is_atom(mod) do
    if BeamLisp.Record.record?(m) do
      if key == :__struct__, do: default, else: Map.get(m, key, default)
    else
      Map.get(m, key, default)
    end
  end

  def get(m, key, default) when is_map(m), do: Map.get(m, key, default)
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
  # A set is a struct, so these MUST precede the is_map clause or they
  # would iterate the struct's fields instead.
  def first(%Set{} = s), do: Set.to_list(s) |> List.first()

  # A record is a struct-map: iterate its public fields (and any assoc'd
  # extras), never the hidden `__struct__` key. These clauses MUST precede
  # the is_map clauses or a record leaks `__struct__` into iteration.
  def first(%{__struct__: mod} = m) when is_atom(mod) do
    if BeamLisp.Record.record?(m), do: first(record_entries(m)), else: first(map_entries(m))
  end

  def first(m) when is_map(m), do: first(map_entries(m))

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

  def rest(%Set{} = s), do: Set.to_list(s) |> tl()

  def rest(%{__struct__: mod} = m) when is_atom(mod) do
    if BeamLisp.Record.record?(m), do: rest(record_entries(m)), else: rest(map_entries(m))
  end

  def rest(m) when is_map(m), do: rest(map_entries(m))

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

  def next(%Set{} = s), do: next(Set.to_list(s))

  def next(%{__struct__: mod} = m) when is_atom(mod) do
    if BeamLisp.Record.record?(m), do: next(record_entries(m)), else: next(map_entries(m))
  end

  def next(m) when is_map(m), do: next(map_entries(m))

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

  @doc "Clojure `conj`: prepend to a list, append to a vector."
  def conj(nil, x), do: [x]
  def conj(xs, x) when is_list(xs), do: [x | xs]
  def conj(%BeamLisp.Vector{} = v, x), do: BeamLisp.Vector.conj(v, x)
  def conj(%LazySeq{} = l, x), do: [x | l]
  # Set conj adds an element (idempotent). A set is a struct, so this
  # must precede the map-entry clause below — a set of vectors is legal
  # and must not be mistaken for a map being conj-ed a [k v] entry.
  def conj(%Set{} = s, x), do: Set.add(s, x)

  # Map conj with a `[k v]` entry (as `find` returns) adds that entry —
  # what select-keys does: `(conj acc (find m k))`. A record conj's the
  # entry too, preserving its type (Map.put keeps the struct); a non-record
  # struct reaching here has no conj contract and fails loudly.
  def conj(m, %BeamLisp.Vector{items: {k, v}}) when is_map(m) and not is_struct(m),
    do: Map.put(m, k, v)

  def conj(%{__struct__: mod} = m, %BeamLisp.Vector{items: {k, v}}) when is_atom(mod) do
    if BeamLisp.Record.record?(m),
      do: Map.put(m, k, v),
      else: raise(ArgumentError, "conj with a map entry is not supported on a struct")
  end

  def count(nil), do: 0
  def count(xs) when is_list(xs), do: length(xs)
  # Both of these are structs, and a struct is a map — they MUST precede
  # the is_map clause or count returns the number of struct fields.
  # (A lazy seq quietly counted 3, its field count, for any length.)
  def count(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.count(v)
  def count(%LazySeq{} = l), do: LazySeq.count(l)
  def count(%Set{} = s), do: Set.count(s)
  # A record's count is its public fields (plus any assoc'd extras) —
  # map_size would count the hidden `__struct__` key too.
  def count(%{__struct__: mod} = m) when is_atom(mod) do
    if BeamLisp.Record.record?(m), do: map_size(m) - 1, else: map_size(m)
  end
  def count(m) when is_map(m), do: map_size(m)
  def count(s) when is_binary(s), do: String.length(s)

  def empty?(%LazySeq{} = l), do: LazySeq.cell(l) == nil
  def empty?(xs), do: count(xs) == 0

  @doc "Lenient element access for sequential destructuring: nil-safe, out-of-range gives nil."
  def nth(nil, _i), do: nil
  def nth(xs, i) when is_list(xs), do: Enum.at(xs, i)
  def nth(%BeamLisp.Vector{} = v, i), do: BeamLisp.Vector.nth(v, i)
  def nth(%LazySeq{} = l, i) when is_integer(i) and i >= 0, do: LazySeq.nth(l, i)
  def nth(%LazySeq{} = _l, _i), do: nil

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
  def seq(%Set{} = s) do
    case Set.to_list(s) do
      [] -> nil
      members -> members
    end
  end

  # A map's seq is its [k v] entries (nil when empty), so `(seq {:a 1})`
  # iterates like Clojure. A record is a struct-map, so its seq reads the
  # public fields, never the hidden `__struct__` key.
  def seq(%{__struct__: mod} = m) when is_atom(mod) do
    if BeamLisp.Record.record?(m), do: seq(record_entries(m)), else: seq(map_entries(m))
  end

  def seq(m) when is_map(m), do: seq(map_entries(m))

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
  def find(%{__struct__: mod} = m, k) when is_atom(mod) do
    if BeamLisp.Record.record?(m) do
      # The internal `__struct__` key is not findable; real keys read the
      # public fields only (never recursing — the deleted map is a plain map).
      if k == :__struct__, do: nil, else: find_in_map(Map.delete(m, :__struct__), k)
    else
      find_in_map(m, k)
    end
  end

  def find(m, k) when is_map(m), do: find_in_map(m, k)

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
  # precede the is_map clause which would check the :members field).
  def contains?(%Set{} = s, x), do: Set.member?(s, x)

  # Records report containment over their public fields only; `__struct__`
  # is internal.
  def contains?(%{__struct__: mod} = m, k) when is_atom(mod) do
    if BeamLisp.Record.record?(m), do: k != :__struct__ and Map.has_key?(m, k), else: Map.has_key?(m, k)
  end

  def contains?(m, k) when is_map(m), do: Map.has_key?(m, k)
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
  def map?(x), do: is_map(x) and not is_struct(x)
  def vector?(%BeamLisp.Vector{}), do: true
  def vector?(_), do: false

  @doc "`list?`: a proper list (incl. the empty list) — never a vector, map, or nil."
  def list?(x) when is_list(x), do: true
  def list?(_), do: false

  def coll?(x) when is_list(x), do: true
  def coll?(%BeamLisp.Vector{}), do: true
  def coll?(m) when is_map(m), do: true
  def coll?(%LazySeq{}), do: true
  def coll?(%Set{}), do: true
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

  @doc "`set?`: true for a set."
  def set?(%Set{}), do: true
  def set?(_), do: false

  @doc "`(disj set x)` — the set without x (idempotent)."
  def disj(%Set{} = s, x), do: Set.del(s, x)

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
  defp rank(%BeamLisp.Vector{}), do: 7
  defp rank(%LazySeq{}), do: 7
  defp rank(%Set{}), do: 7
  defp rank(x) when is_list(x), do: 7
  defp rank(x) when is_map(x), do: 7
  defp rank(_), do: 8

  defp cmp_same(3, a, b), do: sign_num(a, b)
  defp cmp_same(4, a, b), do: sign_str(a, b)
  defp cmp_same(5, a, b), do: sign_str(sym_name(a), sym_name(b))
  defp cmp_same(6, a, b), do: sign_str(Atom.to_string(a), Atom.to_string(b))
  defp cmp_same(7, a, b), do: compare_seqs(a, b)
  defp cmp_same(_, _, _), do: 0

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
    if is_nil(ns), do: String.to_atom(name), else: String.to_atom(ns <> "/" <> name)
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

  @doc "jank's `cpp/jank.runtime.is_sorted`: beam-lisp has no sorted collection type, so nothing is one."
  def sorted?(_), do: false

  @doc "jank's `cpp/jank.runtime.is_nan`: true for a NaN float (the only value unequal to itself)."
  def nan?(x) when is_float(x), do: x != x
  def nan?(_), do: false

  @doc """
  Clojure `=`: for lazy operands, realize-and-compare element-wise with
  short-circuiting, so `(= (range) '(1 2))` stops at the first mismatch
  instead of realizing an infinite seq. Non-lazy operands take the plain
  `==` fast path, preserving existing equality exactly.
  """
  def eqv(a, b) do
    # Walk whenever an operand is lazy *or* an improper list (a
    # partially-realized `[h | LazySeq]`), so a lazy interleave result
    # compares element-wise against a proper list instead of failing the
    # structural `==` that distinguishes improper from proper.
    if LazySeq.lazy?(a) or LazySeq.lazy?(b) or improper?(a) or improper?(b) do
      eqv_walk(a, b)
    else
      Kernel.==(a, b)
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
  # The prelude's strict seq fns are *hybrid*: a realized input (list or
  # vector) flows through the strict `Enum` path so existing equality and
  # Elixir interop hold unchanged; a `LazySeq` input composes lazily so
  # `(take 5 (map f (range)))` never realizes what it does not need.

  # Clojure treats nil as an empty seq everywhere a seq is expected:
  # `(map f nil)` is `()`, not an error. An exhausted `& rest` binds
  # nil, so upstream code passes nil into seq fns constantly.
# A map becomes a seq of `[k v]` entry vectors — the Clojure MapEntry
  # shape — so first/rest/seq/next and reduce all see pairs. Elixir map
  # enumeration is insertion-ordered, keeping key order deterministic.
  defp map_entries(m), do: for({k, v} <- m, do: %BeamLisp.Vector{items: {k, v}})

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
  # A record iterates as its public entries, not its struct fields.
  defp seqable(%{__struct__: mod} = r) when is_atom(mod) do
    if BeamLisp.Record.record?(r), do: record_entries(r), else: r
  end
  defp seqable(coll), do: coll

  def map(f, coll) do
    if LazySeq.lazy?(coll) do
      lazy_map(f, coll)
    else
      coll |> seqable() |> Enum.map(&invoke(f, [&1])) |> empty_contract()
    end
  end

  defp lazy_map(f, coll) do
    LazySeq.new(fn ->
      case LazySeq.cell(coll) do
        nil -> nil
        [h | t] -> [invoke(f, [h]) | lazy_map(f, t)]
      end
    end)
  end

  def filter(pred, coll) do
    if LazySeq.lazy?(coll) do
      lazy_filter(pred, coll)
    else
      coll |> seqable() |> Enum.filter(&invoke(pred, [&1])) |> empty_contract()
    end
  end

  defp lazy_filter(pred, coll) do
    LazySeq.new(fn ->
      case skip_filter(pred, coll) do
        nil -> nil
        [h | t] -> [h | lazy_filter(pred, t)]
      end
    end)
  end

  defp skip_filter(pred, coll) do
    case LazySeq.cell(coll) do
      nil -> nil
      [h | t] -> if invoke(pred, [h]), do: [h | t], else: skip_filter(pred, t)
    end
  end

  @doc """
  `(range)` is an infinite lazy seq. Bounded `(range end)` and
  `(range start end)` stay eager (realized lists) so `(= (range 5) '(0 1 2 3 4))`
  holds under structural equality.
  """
  def range(), do: LazySeq.new(fn -> range_from(0) end)
  def range(end_), do: range(0, end_)
  def range(start, end_) when start >= end_, do: []
  def range(start, end_), do: Enum.to_list(start..(end_ - 1))

  defp range_from(i), do: [i | LazySeq.new(fn -> range_from(i + 1) end)]

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

  @doc "`(concat & seqs)` — lazy when any input is lazy, else a realized flat list."
  def concat(seqs) when is_list(seqs) do
    if Enum.any?(seqs, &LazySeq.lazy?/1) do
      LazySeq.new(fn -> concat_from(seqs) end)
    else
      Enum.flat_map(seqs, &(LazySeq.cell(&1) || []))
    end
  end

  defp concat_from([]), do: nil

  defp concat_from([s | rest]) do
    case LazySeq.cell(s) do
      nil -> concat_from(rest)
      [h | t] -> [h | LazySeq.new(fn -> concat_from([t | rest]) end)]
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

  def take_while(pred, coll) do
    if LazySeq.lazy?(coll) do
      LazySeq.new(fn ->
        case LazySeq.cell(coll) do
          nil -> nil
          [h | t] -> if invoke(pred, [h]), do: [h | take_while(pred, t)], else: nil
        end
      end)
    else
      Enum.take_while(coll, &invoke(pred, [&1]))
    end
  end

  def drop_while(pred, coll) do
    if LazySeq.lazy?(coll) do
      LazySeq.new(fn -> drop_while_skip(pred, coll) end)
    else
      Enum.drop_while(coll, &invoke(pred, [&1]))
    end
  end

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
  # A set is a struct (and so a map) — this must precede the is_map
  # clause or assoc would silently add a field to the struct. Clojure
  # raises; fail loudly instead of corrupting the set's shape.
  def assoc(%Set{}, _k, _v),
    do: raise(ArgumentError, "assoc not supported on a set")
  # A record's `__struct__` key is internal; assoc'ing it would silently
  # turn the record into a corrupted plain map, so fail loudly instead.
  def assoc(%{__struct__: mod} = m, k, v) when is_atom(mod) and k == :__struct__ do
    if BeamLisp.Record.record?(m),
      do: raise(ArgumentError, "assoc on the internal :__struct__ key is not allowed on a record"),
      else: Map.put(m, k, v)
  end
  def assoc(coll, k, v) when is_map(coll), do: Map.put(coll, k, v)
  def assoc(nil, k, v), do: Map.put(%{}, k, v)

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
  # precede the is_map clause.)
  def print_str(%Set{} = s) do
    body = s |> Set.to_list() |> Enum.map_join(" ", &print_elem/1)
    "#" <> "{" <> body <> "}"
  end

  # A record prints readably as `#ns/Name{field val …}` — the tagged
  # literal form the reader lowers back into a record, so `pr-str` then
  # read round-trips to an equal record (a plain map print would come
  # back as a map, breaking record equality). The `"#" <>` splice avoids
  # the `#{` Elixir-interpolation pitfall.
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

  def print_str(m) when is_map(m), do: print_str_map(m)

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

  def println(x), do: IO.puts(print_str(x))

  # The reader-macro table: dispatch-char → wrapper symbol name.
  # Lives in the vars ETS table (same registry as vars); the reader
  # consults it for `@`, core.bl registers the mapping, users may
  # rebind it. `(reader-macro! "@" (quote deref))`.
  def reader_macro(char) do
    case :ets.lookup(:beam_lisp_vars, {:reader_macro, char}) do
      [{{:reader_macro, ^char}, name}] -> {:ok, name}
      [] -> :error
    end
  end

  def reader_macro!(char, {:symbol, name}) when is_binary(char) do
    :ets.insert(:beam_lisp_vars, {{:reader_macro, char}, name})
    name
  end

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
      "conj" => &conj/2,
      "count" => &count/1,
      "nth" => &nth/2,
      "empty?" => &empty?/1,
      "get" => multi_fn(%{2 => &get/2, 3 => &get/3}),
      "assoc" => multi_fn(%{3 => &assoc/3}, {3, &assoc_variadic/4}),
      "apply" => multi_fn(%{2 => &apply_to/2}, {2, &apply_variadic/3}),
      "next" => &next/1,
      "list*" => multi_fn(%{0 => &list_star_0/0}, {1, &list_star/2}),
      "println" => &println/1,
      "pr-str" => &print_str/1,
      # Clojure's `print-str` returns the printed representation (like
      # pr-str, minus readably-quoted strings); both share the one printer.
      "print-str" => &print_str/1,
      "gensym" => multi_fn(%{0 => &gensym/0, 1 => &gensym/1}),
      # lazy sequences: hybrid — realized in → realized out, lazy in → lazy out
      "map" => &map/2,
      "filter" => &filter/2,
      "range" => multi_fn(%{0 => &range/0, 1 => &range/1, 2 => &range/2}),
      "iterate" => &iterate/2,
      "repeat" => multi_fn(%{1 => &repeat/1, 2 => &repeat/2}),
      "cycle" => &cycle/1,
      "concat" => multi_fn(%{}, {0, fn args -> concat(args) end}),
      "take" => &take/2,
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
      "vector?" => &vector?/1,
      "list?" => &list?/1,
      "coll?" => &coll?/1,
      "ident?" => &ident?/1,
      # sets (wave 18)
      "set" => &set/1,
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
      "reader-macro!" => &reader_macro!/2
    }

    prims = Map.merge(prims, refs_prims)

    # Transients: mutable-until-persisted views of vectors and maps.
    # Fixed arities are plain fns; hash-map is variadic (even forms).
    transient_prims = %{
      "transient" => &BeamLisp.Transient.transient/1,
      "persistent!" => &BeamLisp.Transient.persistent!/1,
      "conj!" => &BeamLisp.Transient.conj!/2,
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
      # predicates report beam-lisp's real type space (no Ratio, no
      # BigDecimal, no sorted coll, so those are genuinely always false).
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
      "jank.runtime.is_volatile" => &BeamLisp.Refs.volatile?/1
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
            {"<=", :"=<"}, {">=", :>=}, {"==", :==}]

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
      "conj" => 2,
      "count" => 1,
      "nth" => 2,
      "empty?" => 1,
      "next" => 1,
      "println" => 1,
      "pr-str" => :print_str,
      "print-str" => :print_str,
      "reader-macro!" => :reader_macro!,
      "assoc" => 3,
      "map" => 2,
      "filter" => 2,
      "take" => 2,
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
      "vector?" => 1,
      "list?" => 1,
      "coll?" => 1,
      "ident?" => 1,
      "set" => 1,
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

    # gensym links both arities directly — plain name, no mangling.
    Env.put_link("core", "gensym", {BeamLisp.RT, %{0 => :gensym, 1 => :gensym}, nil})

    # `get` fixes its 2-arity fallback (which `RT.invoke` needs when a
    # 2-arg call misses the old 3-arity link) and keeps the 3-arity fast
    # path. `drop` is Clojure-ordered (`(drop n coll)`) via `drop_clj`.
    Env.put_link("core", "get", {BeamLisp.RT, %{2 => :get, 3 => :get}, nil})
    Env.put_link("core", "drop", {BeamLisp.RT, %{2 => :drop_clj}, nil})

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
      "conj!" => {BeamLisp.Transient, %{2 => :conj!}, nil},
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
