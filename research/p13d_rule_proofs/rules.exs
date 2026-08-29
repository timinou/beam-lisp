# P13d — SMT-verified deodorant rules
#
# Run: elixir research/p13d_rule_proofs/rules.exs   (requires z3 on PATH)
#
# Can the solver (a) PROVE deodorant's SAFE rules, (b) DERIVE the
# assumption behind an IDIOMATIC rule from a counterexample, and
# (c) CATCH a deliberately broken rule?
#
# Value model (same tagged encoding as P13a): a beam-lisp value is
# (tag_x : Int, x_i : Int). Tags: nil=0, int=1, string=3, bool=5.
# Soundness of a rewrite  lhs → rhs  means: same RESULT and same
# RAISED-NESS for every input. `=` never raises; `zero?` raises on
# non-numbers — that asymmetry is what makes the idiomatic tier real.

defmodule Prove do
  def open do
    Port.open({:spawn_executable, System.find_executable("z3")},
              [:binary, :stream, :use_stdio, args: ["-in"]])
  end

  def ask(port, smt) do
    Port.command(port, "(reset)\n" <> smt)
    read(port, "")
  end

  defp read(port, acc) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data
        lines = String.split(acc, "\n")
        # scan for the first answer line; z3 may emit (error ...) or
        # other lines before it
        case Enum.find_index(lines, &(&1 in ["sat", "unsat", "unknown", "error"])) do
          nil ->
            read(port, acc)

          idx ->
            line = Enum.at(lines, idx)
            rest = lines |> Enum.drop(idx + 1) |> Enum.join("\n")

            if line == "sat" do
              Port.command(port, "(get-model)\n")
              # `rest` may already hold model bytes from the same chunk.
              {line, read_model(port, rest)}
            else
              {line, nil}
            end
        end
    after
      10_000 -> raise "z3 timeout (acc: #{inspect(acc)})"
    end
  end

  defp read_model(port, acc) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data
        # model closes when parens balance after a non-empty body
        if String.length(acc) > 3 and balanced?(acc), do: acc, else: read_model(port, acc)
    after
      10_000 -> acc
    end
  end

  defp balanced?(s), do: String.graphemes(s) |> Enum.reduce(0, fn
    "(", n -> n + 1
    ")", n -> n - 1
    _, n -> n
  end) == 0

  # assert_not_equiv: unsat ⇒ lhs ≡ rhs (PROVEN); sat ⇒ model is a
  # counterexample input.
  def assert_not_equiv(decls, lhs, rhs) do
    decls <>
      "(assert (not (and (= #{lhs[:result]} #{rhs[:result]}) (= #{lhs[:raises]} #{rhs[:raises]}))))\n" <>
      "(check-sat)\n"
  end
end

defmodule Rules do
  @value_decls """
  (declare-const tag_x Int)
  (declare-const x_i Int)
  (assert (or (= tag_x 0) (= tag_x 1) (= tag_x 3) (= tag_x 5)))
  """

  @doc """
  SAFE candidate: (if p true false) → (boolean p), over Bool p.
  boolean is identity on bools and never raises; the `if` returns the
  bool itself. Both sides: result = p, raises = false.
  """
  def if_true_false(port) do
    decls = "(declare-const p Bool)\n"
    lhs = %{result: "(ite p true false)", raises: "false"}
    rhs = %{result: "p", raises: "false"}
    Prove.ask(port, Prove.assert_not_equiv(decls, lhs, rhs))
  end

  @doc """
  SAFE candidate: (not (nil? x)) → (some? x). nil? ⇔ tag=0; some? ⇔
  tag≠0; neither raises.
  """
  def not_nil_to_some(port) do
    lhs = %{result: "(not (= tag_x 0))", raises: "false"}
    rhs = %{result: "(not (= tag_x 0))", raises: "false"}
    Prove.ask(port, Prove.assert_not_equiv(@value_decls, lhs, rhs))
  end

  @doc """
  IDIOMATIC: (= x 0) → (zero? x).
  `=` is total: result = (tag=1 ∧ x_i=0), never raises.
  `zero?` is partial: RAISES unless tag=1; when tag=1, result = (x_i=0).
  Expect: sat with tag_x=string counterexample ⇒ the derived assumption
  is exactly "x : int" — which the checker's tag lattice can discharge
  per call site.
  """
  def eq_zero_to_zero?(port) do
    lhs = %{result: "(and (= tag_x 1) (= x_i 0))", raises: "false"}
    rhs = %{result: "(= x_i 0)", raises: "(not (= tag_x 1))"}
    Prove.ask(port, Prove.assert_not_equiv(@value_decls, lhs, rhs))
  end

  @doc "Same rule UNDER the discharged assumption (tag_x = int): expect proven."
  def eq_zero_under_assumption(port) do
    decls = @value_decls <> "(assert (= tag_x 1))\n"
    lhs = %{result: "(and (= tag_x 1) (= x_i 0))", raises: "false"}
    rhs = %{result: "(= x_i 0)", raises: "(not (= tag_x 1))"}
    Prove.ask(port, Prove.assert_not_equiv(decls, lhs, rhs))
  end

  @doc "Deliberately broken: (= x 1) → (zero? x). Expect counterexample x=1."
  def broken_rule(port) do
    lhs = %{result: "(and (= tag_x 1) (= x_i 1))", raises: "false"}
    rhs = %{result: "(= x_i 0)", raises: "(not (= tag_x 1))"}
    Prove.ask(port, Prove.assert_not_equiv(@value_decls, lhs, rhs))
  end
end

port = Prove.open()
IO.puts("== P13d: deodorant rules under the solver (z3) ==\n")

report = fn label, {verdict, model}, proven_means ->
  case verdict do
    "unsat" -> IO.puts("#{label}: PROVEN (#{proven_means})")
    "sat"   -> IO.puts("#{label}: COUNTEREXAMPLE ⇒#{model}")
    other   -> IO.puts("#{label}: #{other}")
  end
end

{t, r} = :timer.tc(fn -> Rules.if_true_false(port) end)
report.("SAFE     (if p true false) → (boolean p)      [#{div(t, 1000)} ms]", r, "equivalent for all p")

{t, r} = :timer.tc(fn -> Rules.not_nil_to_some(port) end)
report.("SAFE     (not (nil? x)) → (some? x)           [#{div(t, 1000)} ms]", r, "equivalent for all x")

{t, r} = :timer.tc(fn -> Rules.eq_zero_to_zero?(port) end)
report.("IDIOMATIC (= x 0) → (zero? x)                 [#{div(t, 1000)} ms]", r, "equivalent")

{t, r} = :timer.tc(fn -> Rules.eq_zero_under_assumption(port) end)
report.("  same rule, x:int discharged by checker      [#{div(t, 1000)} ms]", r, "SOUND under inferred x:int — auto-promoted to SAFE")

{t, r} = :timer.tc(fn -> Rules.broken_rule(port) end)
report.("BROKEN   (= x 1) → (zero? x)   (on purpose)   [#{div(t, 1000)} ms]", r, "should never happen")

Port.close(port)
IO.puts("")
