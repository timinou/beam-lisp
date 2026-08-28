# P13a — SMT encoding spike: beam-lisp guards → SMT-LIB → z3
#
# Run: elixir research/p13a_smt/encode.exs
#
# Questions under test:
#   1. Can bl guard expressions be MECHANICALLY encoded to SMT-LIB with
#      correct dynamic-value semantics?
#   2. What does the dynamic-value encoding cost vs direct encoding?
#   3. Per-query latency: fresh process vs persistent `z3 -in` port.
#
# Forms are Elixir sexps standing in for reader output:
#   [:and, [:>, :x, 3], [:<, :x, 3]]  ==  (and (> x 3) (< x 3))
# The tag env simulates the lattice layer's narrowing: %{x: :int}.

defmodule Enc do
  # Tag ids for the tagged encoding (models a dynamically-typed value as
  # a tag Int + per-sort payload consts).
  @tags %{int: 1, float: 2, string: 3, keyword: 4, bool: 5, map: 6, vec: 7, set: 8, fn: 9, nil: 10}
  @numeric [:int, :float, :number]
  @tag_preds %{:int? => :int, :float? => :float, :string? => :string,
               :keyword? => :keyword, :bool? => :bool, :map? => :map,
               :vector? => :vec, :set? => :set, :fn? => :fn, :nil? => :nil}
  @cmps %{:> => ">", :< => "<", :>= => ">=", :<= => "<=", := => "="}

  # Returns {:ok, smtlib_string} | :unknown (sound-warnings-only: drop).
  # mode :direct — only provably-numeric vars encoded, tag predicates
  #   resolved against the tag env at encode time.
  # mode :tagged — every var gets tag + payload consts; tag predicates
  #   become runtime assertions. Measures the dynamic-typing tax.
  def encode(form, tags, mode) do
    case expr(form, tags, mode) do
      {:ok, sexp} -> {:ok, "(assert #{sexp})\n(check-sat)\n"}
      :unknown -> :unknown
    end
  end

  defp expr([:and | ps], tags, mode), do: nary("and", ps, tags, mode)
  defp expr([:or | ps], tags, mode), do: nary("or", ps, tags, mode)

  defp expr([:not, p], tags, mode) do
    case expr(p, tags, mode) do
      {:ok, s} -> {:ok, "(not #{s})"}
      :unknown -> :unknown
    end
  end

  defp expr([pred, x], tags, mode) when is_atom(pred) and is_atom(x) do
    cond do
      pred in [:zero?, :pos?, :neg?] ->
        numeric_cmp(x, pred, tags, mode)

      Map.has_key?(@tag_preds, pred) ->
        tag_pred(@tag_preds[pred], x, tags, mode)

      true ->
        :unknown
    end
  end

  defp expr([op, a, b], tags, mode) when op in [:>, :<, :>=, :<=, :=] do
    with {:ok, sa} <- operand(a, tags, mode),
         {:ok, sb} <- operand(b, tags, mode) do
      {:ok, "(#{@cmps[op]} #{sa} #{sb})"}
    end
  end

  defp expr(_, _, _), do: :unknown

  defp nary(name, ps, tags, mode) do
    encoded = Enum.map(ps, &expr(&1, tags, mode))

    # A dropped conjunct can only WEAKEN a conjunction (unsat stays
    # sound: if the subset is unsat, the full set is unsat). For `or`
    # it could strengthen — so any unknown disjunct sinks the whole `or`.
    case {name, Enum.any?(encoded, &(&1 == :unknown))} do
      {"or", true} -> :unknown
      _ ->
        case for({:ok, s} <- encoded, do: s) do
          [] -> :unknown
          [single] -> {:ok, single}
          xs -> {:ok, "(#{name} #{Enum.join(xs, " ")})"}
        end
    end
  end

  defp numeric_cmp(x, pred, tags, mode) do
    op = %{zero?: "=", pos?: ">", neg?: "<"}[pred]
    with true <- numeric?(x, tags),
         {:ok, sx} <- operand(x, tags, mode) do
      {:ok, "(#{op} #{sx} 0)"}
    else
      _ -> :unknown
    end
  end

  defp tag_pred(tag, x, tags, :direct) do
    # The lattice layer already knows — resolve statically.
    case Map.get(tags, x) do
      nil -> :unknown
      ^tag -> {:ok, "true"}
      _other -> {:ok, "false"}
    end
  end

  defp tag_pred(tag, x, _tags, :tagged) do
    {:ok, "(= tag_#{x} #{@tags[tag]})"}
  end

  defp operand(x, tags, mode) when is_atom(x) do
    cond do
      mode == :tagged -> {:ok, "#{x}_i"}
      numeric?(x, tags) -> {:ok, Atom.to_string(x)}
      true -> :unknown
    end
  end

  defp operand(n, _, _) when is_integer(n), do: {:ok, Integer.to_string(n)}
  defp operand(_, _, _), do: :unknown

  defp numeric?(x, tags), do: Map.get(tags, x) in @numeric

  def decls(form, tags, :direct) do
    vars = form |> List.flatten() |> Enum.filter(&is_atom/1) |> Enum.uniq()

    vars
    |> Enum.filter(&(Map.get(tags, &1) in @numeric))
    |> Enum.map(&"(declare-const #{&1} Int)\n")
    |> Enum.join()
  end

  def decls(form, _tags, :tagged) do
    vars =
      form
      |> List.flatten()
      |> Enum.filter(fn x -> is_atom(x) and not Map.has_key?(@cmps, x) and
                             x not in [:and, :or, :not] and
                             not Map.has_key?(@tag_preds, x) and
                             x not in [:zero?, :pos?, :neg?] end)
      |> Enum.uniq()

    Enum.map_join(vars, "", fn v ->
      "(declare-const tag_#{v} Int)\n(declare-const #{v}_i Int)\n"
    end)
  end
end

defmodule Runner do
  # Fresh-process query: correctness reference, and the cold-latency number.
  def query(smt) do
    path = Path.join(System.tmp_dir!(), "p13a-#{:erlang.unique_integer([:positive])}.smt2")
    File.write!(path, smt)
    {t, {out, 0}} = :timer.tc(fn -> System.cmd("z3", ["-smt2", path]) end)
    File.rm(path)
    {String.trim(out), div(t, 1000)}
  end

  # Persistent `z3 -in` over a port: the realistic integration shape.
  def open_port do
    Port.open({:spawn_executable, System.find_executable("z3")},
              [:binary, :stream, :use_stdio, args: ["-in"]])
  end

  def query_port(port, smt) do
    {t, result} = :timer.tc(fn ->
      Port.command(port, smt)
      read_answer(port, "")
    end)
    {result, div(t, 1000)}
  end

  defp read_answer(port, acc) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data

        if String.contains?(acc, ["sat", "unsat", "unknown"]) do
          acc |> String.split() |> hd()
        else
          read_answer(port, acc)
        end
    after
      5_000 -> raise "z3 port timeout"
    end
  end
end

defmodule Bench do
  def run do
    IO.puts("== P13a: beam-lisp guard → SMT-LIB → z3 #{z3_version()} ==\n")

    queries = [
      {"contradiction (and (> x 3) (< x 3))",
       [:and, [:>, :x, 3], [:<, :x, 3]], %{x: :int}},
      {"satisfiable (and (> x 3) (int? x))",
       [:and, [:>, :x, 3], [:int?, :x]], %{x: :int}},
      {"tag contradiction (and (int? y) (string? y))",
       [:and, [:int?, :y], [:string?, :y]], %{y: :int}},
      {"datom-style bound check (and (>= i n) (< i n))",
       [:and, [:>=, :i, :n], [:<, :i, :n]], %{i: :int, n: :int}},
      {"relational x > y + 3... via two conjuncts (and (> x (+ y 3)) (< x y)) — out of grammar, expect :unknown",
       [:and, [:>, :x, [:+, :y, 3]], [:<, :x, :y]], %{x: :int, y: :int}}
    ]

    for {label, form, tags} <- queries do
      IO.puts("-- #{label}")

      for mode <- [:direct, :tagged] do
        case Enc.encode(form, tags, mode) do
          {:ok, body} ->
            smt = Enc.decls(form, tags, mode) <> body
            {answer, ms} = Runner.query(smt)
            IO.puts("   #{mode}: #{answer} (#{ms} ms cold)")

          :unknown ->
            IO.puts("   #{mode}: :unknown (dropped — sound-warnings-only)")
        end
      end

      IO.puts("")
    end

    latency()
  end

  defp latency do
    IO.puts("== latency: 100 queries, tagged encoding, (and (> x 3) (< x 3)) ==")

    form = [:and, [:>, :x, 3], [:<, :x, 3]]
    {:ok, body} = Enc.encode(form, %{x: :int}, :tagged)
    smt = Enc.decls(form, %{x: :int}, :tagged) <> body

    cold = for _ <- 1..100, do: elem(Runner.query(smt), 1)

    port = Runner.open_port()
    # warmup
    for _ <- 1..5, do: Runner.query_port(port, smt <> "(reset)\n")
    warm = for _ <- 1..100, do: elem(Runner.query_port(port, smt <> "(reset)\n"), 1)
    Port.close(port)

    report("fresh process", cold)
    report("persistent port", warm)
  end

  defp report(label, samples) do
    sorted = Enum.sort(samples)
    p50 = Enum.at(sorted, 49)
    p99 = Enum.at(sorted, 98)
    IO.puts("   #{label}: p50=#{p50} ms  p99=#{p99} ms  max=#{List.last(sorted)} ms")
  end

  defp z3_version do
    {v, 0} = System.cmd("z3", ["--version"])
    String.trim(v)
  end
end

Bench.run()
