defmodule BeamLisp.RT do
  @moduledoc """
  Runtime primitives seeded into the `core` namespace before any
  beam-lisp code runs. Everything here is an ordinary Elixir function
  value, so compiled beam-lisp code calls them with plain `apply/2`.
  """

  alias BeamLisp.{Env, LazySeq}

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

  @doc "A first-class handle to a remote function, e.g. `(map String/upcase xs)`."
  def remote_fun(module, fun), do: {:"$remote", module, fun}

  def get(m, key, default \\ nil)
  # A vector is a struct, so it is also a map — index access must be
  # matched before the map clause or `(get [a b] 1)` silently yields
  # the default.
  def get(%BeamLisp.Vector{} = v, i, _default), do: BeamLisp.Vector.nth(v, i)
  def get(m, key, default) when is_map(m), do: Map.get(m, key, default)
  def get(nil, _key, default), do: default

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

  # `next`'s tail is either a realized list (seq it → nil if empty) or a
  # LazySeq (return it untouched — forcing it would realize a second cell).
  defp next_tail(%LazySeq{} = t), do: t
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

  def count(nil), do: 0
  def count(xs) when is_list(xs), do: length(xs)
  def count(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.count(v)
  def count(m) when is_map(m), do: map_size(m)
  def count(s) when is_binary(s), do: String.length(s)
  def count(%LazySeq{} = l), do: LazySeq.count(l)

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
  def find(m, k) when is_map(m) do
    case Map.fetch(m, k) do
      {:ok, v} -> %BeamLisp.Vector{items: {k, v}}
      :error -> nil
    end
  end

  def find(_m, _k), do: nil

  @doc """
  `contains?`: KEY membership for maps, index-in-range for vectors — never
  value membership (the classic Clojure trap).
  """
  def contains?(%BeamLisp.Vector{} = v, i) when is_integer(i),
    do: i >= 0 and i < BeamLisp.Vector.count(v)

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
  def coll?(_), do: false

  @doc "`ident?`: a keyword or a symbol."
  def ident?(x) when is_atom(x), do: x not in [true, false, nil]
  def ident?({:symbol, _}), do: true
  def ident?(_), do: false

  @doc """
  Clojure `=`: for lazy operands, realize-and-compare element-wise with
  short-circuiting, so `(= (range) '(1 2))` stops at the first mismatch
  instead of realizing an infinite seq. Non-lazy operands take the plain
  `==` fast path, preserving existing equality exactly.
  """
  def eqv(a, b) do
    if LazySeq.lazy?(a) or LazySeq.lazy?(b), do: eqv_walk(a, b), else: Kernel.==(a, b)
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
  defp seqable(nil), do: []
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

  @doc "`(doall coll)` fully realizes a lazy seq, returning it."
  def doall(%LazySeq{} = l), do: LazySeq.to_list(l)
  def doall(coll), do: coll

  @doc "`(dorun coll)` forces a lazy seq for side effects, returning nil."
  def dorun(%LazySeq{} = l) do
    LazySeq.run(l)
    nil
  end

  def dorun(_coll), do: nil

  @doc "Clojure `assoc`: maps get a key update, vectors an index update (append at count)."
  def assoc(coll, k, v)
  def assoc(%BeamLisp.Vector{} = v, i, x), do: BeamLisp.Vector.assoc(v, i, x)
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
  def print_str(x) when is_list(x), do: "(" <> Enum.map_join(x, " ", &print_elem/1) <> ")"

  def print_str(%LazySeq{} = l) do
    {elems, truncated} = LazySeq.sample(l, 20)
    body = Enum.map_join(elems, " ", &print_elem/1)
    suffix = if truncated, do: " …", else: ""
    "(" <> body <> suffix <> ")"
  end

  def print_str(m) when is_map(m) do
    pairs = Enum.map_join(m, ", ", fn {k, v} -> print_elem(k) <> " " <> print_elem(v) end)
    "{" <> pairs <> "}"
  end

  def print_str(x), do: inspect(x)

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
  defp to_str(x), do: to_string(x)

  # Fresh, collision-proof symbol datum for hand-written macros. Shares
  # the `__N__auto` shape with syntax-quote `x#` auto-gensyms.
  def gensym(), do: gensym("G")

  def gensym(prefix) when is_binary(prefix) do
    {:symbol,
     prefix <> "__" <> Integer.to_string(System.unique_integer([:positive])) <> "__auto"}
  end

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
      "ident?" => &ident?/1
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
      "reader-macro!" => &reader_macro!/2
    }

    prims = Map.merge(prims, refs_prims)
    Enum.each(prims, fn {name, f} -> Env.intern("core", name, f) end)
    seed_links()
    :ok
  end

  # Prims link to direct calls too: operators to their :erlang BIFs,
  # seq fns to BeamLisp.RT. Only arities whose semantics match
  # exactly get linked — everything else falls back to invoke.
  defp seed_links do
    bif2 = [:+, :-, :*, :/, :<, :>, :<=, :>=, :==]

    for op <- bif2 do
      Env.put_link("core", to_string(op), {:erlang, %{2 => op}, nil})
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
      "ident?" => 1
    }

    for {name, spec} <- rt_fns do
      {fname, arity} =
        case spec do
          a when is_atom(a) -> {a, 2}
          n when is_integer(n) -> {String.to_atom(name), n}
        end

      Env.put_link("core", name, {BeamLisp.RT, %{arity => fname}, nil})
    end

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

    :ok
  end
end
