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

  def rest(nil), do: []
  def rest([]), do: []
  def rest([_ | t]), do: t

  def cons(x, nil), do: [x]
  def cons(x, xs) when is_list(xs), do: [x | xs]

  def count(nil), do: 0
  def count(xs) when is_list(xs), do: length(xs)
  def count(m) when is_map(m), do: map_size(m)
  def count(s) when is_binary(s), do: String.length(s)

  def empty?(xs), do: count(xs) == 0

  @doc "Lenient element access for sequential destructuring: nil-safe, out-of-range gives nil."
  def nth(nil, _i), do: nil
  def nth(xs, i) when is_list(xs), do: Enum.at(xs, i)

  @doc "Lenient tail access for sequential destructuring: nil-safe."
  def drop(nil, _n), do: []
  def drop(xs, n) when is_list(xs), do: Enum.drop(xs, n)

  def print_str({:"$blfn", _, nil}), do: "#fn[multi-arity]"
  def print_str({:"$blfn", _, _}), do: "#fn[variadic]"
  def print_str({:"$remote", m, f}), do: "#fn[#{m}/#{f}]"
  def print_str(x) when is_binary(x), do: x
  def print_str({:symbol, name}), do: name
  def print_str(x) when is_atom(x), do: Atom.to_string(x)
  def print_str(x) when is_list(x), do: "(" <> Enum.map_join(x, " ", &print_str/1) <> ")"
  def print_str(x), do: inspect(x)

  @doc false
  def str do
    multi_fn(%{
      1 => fn x -> to_str(x) end,
      2 => fn x, y -> to_str(x) <> to_str(y) end
    })
  end

  defp to_str(nil), do: ""
  defp to_str(x) when is_binary(x), do: x
  defp to_str(x) when is_atom(x), do: Atom.to_string(x)
  defp to_str(x), do: to_string(x)

  @doc "Seed `core` with the primitives the prelude and interop need."
  def seed_core do
    prims = %{
      "+" => &Kernel.+/2,
      "-" => &Kernel.-/2,
      "*" => &Kernel.*/2,
      "/" => &Kernel.//2,
      "<" => &Kernel.</2,
      ">" => &Kernel.>/2,
      "<=" => &Kernel.<=/2,
      ">=" => &Kernel.>=/2,
      "=" => &Kernel.==/2,
      "not" => &Kernel.not/1,
      "str" => str(),
      "first" => &first/1,
      "rest" => &rest/1,
      "cons" => &cons/2,
      "count" => &count/1,
      "empty?" => &empty?/1,
      "get" => &get/3,
      "apply" => &apply/2,
      "println" => fn x -> IO.puts(print_str(x)) end,
      "pr-str" => &print_str/1
    }

    Enum.each(prims, fn {name, f} -> Env.intern("core", name, f) end)
    :ok
  end
end
