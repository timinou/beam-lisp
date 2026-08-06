defmodule BeamLisp.RT do
  @moduledoc """
  Runtime primitives seeded into the `core` namespace before any
  beam-lisp code runs. Everything here is an ordinary Elixir function
  value, so compiled beam-lisp code calls them with plain `apply/2`.
  """

  alias BeamLisp.Env

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

  @doc "A first-class handle to a remote function, e.g. `(map String/upcase xs)`."
  def remote_fun(module, fun), do: {:"$remote", module, fun}

  def get(m, key, default \\ nil)
  def get(m, key, default) when is_map(m), do: Map.get(m, key, default)
  def get(nil, _key, default), do: default

  def first(nil), do: nil
  def first([]), do: nil
  def first([h | _]), do: h
  def first(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.first(v)

  def rest(nil), do: []
  def rest([]), do: []
  def rest([_ | t]), do: t
  def rest(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.rest(v)

  def cons(x, nil), do: [x]
  def cons(x, xs) when is_list(xs), do: [x | xs]
  def cons(x, %BeamLisp.Vector{} = v), do: [x | BeamLisp.Vector.to_list(v)]

  @doc "Clojure `conj`: prepend to a list, append to a vector."
  def conj(nil, x), do: [x]
  def conj(xs, x) when is_list(xs), do: [x | xs]
  def conj(%BeamLisp.Vector{} = v, x), do: BeamLisp.Vector.conj(v, x)

  def count(nil), do: 0
  def count(xs) when is_list(xs), do: length(xs)
  def count(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.count(v)
  def count(m) when is_map(m), do: map_size(m)
  def count(s) when is_binary(s), do: String.length(s)

  def empty?(xs), do: count(xs) == 0

  @doc "Lenient element access for sequential destructuring: nil-safe, out-of-range gives nil."
  def nth(nil, _i), do: nil
  def nth(xs, i) when is_list(xs), do: Enum.at(xs, i)
  def nth(%BeamLisp.Vector{} = v, i), do: BeamLisp.Vector.nth(v, i)

  @doc "Lenient tail access for sequential destructuring: nil-safe."
  def drop(nil, _n), do: []
  def drop(xs, n) when is_list(xs), do: Enum.drop(xs, n)
  def drop(%BeamLisp.Vector{} = v, n), do: BeamLisp.Vector.drop(v, n)

  @doc "`(apply f args)` — accepts lists and vectors, and dispatches tagged fns like any other call."
  def apply_to(f, args) when is_list(args), do: invoke(f, args)
  def apply_to(f, %BeamLisp.Vector{} = v), do: invoke(f, BeamLisp.Vector.to_list(v))

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

  def print_str(m) when is_map(m) do
    pairs = Enum.map_join(m, ", ", fn {k, v} -> print_elem(k) <> " " <> print_elem(v) end)
    "{" <> pairs <> "}"
  end

  def print_str(x), do: inspect(x)

  def println(x), do: IO.puts(print_str(x))

  # Inside a collection, strings print readably; at the top level
  # (println, pr-str of a bare string) they print raw.
  defp print_elem(x) when is_binary(x), do: inspect(x)
  defp print_elem(x), do: print_str(x)

  @doc false
  def str do
    multi_fn(%{}, {0, fn args -> Enum.map_join(args, "", &to_str/1) end})
  end

  defp to_str(nil), do: ""
  defp to_str(x) when is_binary(x), do: x
  defp to_str(x) when is_atom(x), do: Atom.to_string(x)
  defp to_str(x), do: to_string(x)

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
      "=" => chain.(&Kernel.==/2),
      "not" => &Kernel.not/1,
      "str" => str(),
      "first" => &first/1,
      "rest" => &rest/1,
      "cons" => &cons/2,
      "conj" => &conj/2,
      "count" => &count/1,
      "empty?" => &empty?/1,
      "get" => &get/3,
      "apply" => &apply_to/2,
      "println" => &println/1,
      "pr-str" => &print_str/1
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
      "future-cancel" => &BeamLisp.Refs.future_cancel/1
    }

    prims = Map.merge(prims, refs_prims)
    Enum.each(prims, fn {name, f} -> Env.intern("core", name, f) end)
    Env.intern("core", "future", future_macro())
    seed_links()
    :ok
  end

  # `(future body…)` → `(BeamLisp.Refs/future_exec (fn [] body…))`.
  # Seeded from Elixir rather than the prelude (which another agent
  # owns). The macro gets the raw arg forms as datum data and returns
  # a form list; the compiler re-reads it, exactly as a beam-lisp
  # defmacro would. `future_exec` is reached by slash syntax (an
  # Elixir module) so the expansion works in any namespace.
  defp future_macro do
    # A macro fn is variadic (like core.bl's `[& body]` macros): the
    # compiler passes each body form as a separate arg, and the
    # multi_fn tag has RT.invoke collect them into one rest list.
    {:"$macro",
     multi_fn(%{}, {0, fn body_forms ->
       [{:symbol, "BeamLisp.Refs/future_exec"},
        [{:symbol, "fn"}, BeamLisp.Vector.new() | body_forms]]
     end})}
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
    Env.put_link("core", "=", {:erlang, %{2 => :==}, nil})

    rt_fns = %{
      "first" => 1,
      "rest" => 1,
      "cons" => 2,
      "conj" => 2,
      "count" => 1,
      "empty?" => 1,
      "get" => 3,
      "nth" => 2,
      "drop" => 2,
      "apply" => :apply_to,
      "println" => 1,
      "pr-str" => :print_str
    }

    for {name, spec} <- rt_fns do
      {fname, arity} =
        case spec do
          a when is_atom(a) -> {a, 2}
          n when is_integer(n) -> {String.to_atom(name), n}
        end

      Env.put_link("core", name, {BeamLisp.RT, %{arity => fname}, nil})
    end

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
