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
      "println" => fn x -> IO.puts(print_str(x)) end,
      "pr-str" => &print_str/1
    })

    Enum.each(prims, fn {name, f} -> Env.intern("core", name, f) end)
    :ok
  end
end
