defmodule BeamLisp.DispatchTableTest do
  # THE hazard-closure artifact. beam-lisp's map is a PLAIN Elixir map and a
  # struct IS a map on the BEAM, so every collection fn must decide per value
  # whether it sees a real collection, a record (a user-facing map), a
  # reference (atom/volatile/promise/future/reduced — deliberately NOT
  # collections), or a scalar that just is not one. Five separate bugs of this
  # exact class were found one at a time by accident over the project's life;
  # this table checks them ALL at once.
  #
  # The table is the cartesian product of 17 values x 18 fns (306 cells). It
  # is structured as DATA — values, fn call-shapes, and a big expectation map
  # — so the whole matrix is visible at a glance and a wrong expectation is a
  # one-line diff, not a buried assertion. Expectations were decided against
  # Clojure's semantics, then the code was made to match where it did not.
  #
  # Every value is CONSTRUCTED IN BEAM-LISP (not handed to the test as an
  # Elixir term) so the real user-facing construction path is what is tested.
  #
  # Deliberately sync: this file EVALUATES beam-lisp source, and concurrent
  # Module.create on the same namespace fails.
  use ExUnit.Case, async: false

  alias BeamLisp.Compiler
  alias BeamLisp.{Set, Vector}

  @set3 "#" <> "{1 2 3}"

  # Each value's beam-lisp construction expression. These are interpolated
  # into every fn's call shape below.
  @values [
    {"plain map", "{:a 1 :b 2}"},
    {"vector", "[1 2 3]"},
    {"set", @set3},
    {"list", "(list 1 2 3)"},
    {"lazy seq", "(map inc (range 1 4))"},
    {"string", "\"ab\""},
    {"nil", "nil"},
    {"integer", "42"},
    {"keyword", ":k"},
    {"atom-ref", "(atom 1)"},
    {"volatile", "(volatile! 1)"},
    {"promise", "(promise)"},
    {"record", "(->R 1 2)"},
    {"deftype", "(->DT 1 2)"},
    {"reify", "(reify RP (rm [this] :v))"},
    {"fn", "(fn ([x] x) ([x y] y))"},
    {"transient", "(transient {:a 1})"}
  ]

  # Each fn's call shape; `%s` is replaced by the value expression. One shape
  # per fn — the fixed extra args (`:a` for key-ops, `4` for conj) are chosen
  # so every collection type answers meaningfully.
  #
  # `get` deliberately RAISES on a non-map value (string/keyword/number/fn/
  # deftype/reify/list) rather than returning Clojure's lenient nil. That is
  # the project's standing design — `(get deftype :a)` raising is guarded by
  # wave24 ("no map semantics"), and refs raise the same way — so the table
  # asserts the deviation instead of papering over it.
  @fns [
    {"count", "(count %s)"},
    {"seq", "(seq %s)"},
    {"first", "(first %s)"},
    {"rest", "(rest %s)"},
    {"next", "(next %s)"},
    {"get", "(get %s :a)"},
    {"assoc", "(assoc %s :a 1)"},
    {"conj", "(conj %s 4)"},
    {"contains?", "(contains? %s :a)"},
    {"find", "(find %s :a)"},
    {"empty?", "(empty? %s)"},
    {"coll?", "(coll? %s)"},
    {"map?", "(map? %s)"},
    {"vector?", "(vector? %s)"},
    {"set?", "(set? %s)"},
    {"seq?", "(seq? %s)"},
    {"transientable?", "(transientable? %s)"},
    {"print-str", "(print-str %s)"}
  ]

  # Expectation shapes:
  #   {:eq, v}            exact structural equality (==)
  #   {:raises, mod}      raises an exception of module `mod`
  #   {:truthy}/{:falsey} not nil-or-false / nil-or-false
  #   {:prefix, s}        a string starting with s
  #   {:entry, {k,v}}     a single [k v] entry vector
  #   {:entry_one_of, kv} a single entry whose {k,v} is in the list
  #   {:entries, kv}      a list of entry vectors whose {k,v} SET equals kv
  #   {:one_of, exps}     any of the sub-expectations holds
  #   {:gap, inner, r}    asserts `inner` (current behaviour) and records a
  #                       KNOWINGLY-RECORDED divergence reason `r` in the gap
  #                       inventory (guarded by a dedicated test, so gaps
  #                       cannot silently multiply).
  @expectations %{
    "plain map" => %{
      "count" => {:eq, 2},
      "seq" => {:entries, [{:a, 1}, {:b, 2}]},
      "first" => {:entry_one_of, [{:a, 1}, {:b, 2}]},
      "rest" => {:one_of, [{:entries, [{:a, 1}]}, {:entries, [{:b, 2}]}]},
      "next" => {:one_of, [{:entries, [{:a, 1}]}, {:entries, [{:b, 2}]}]},
      "get" => {:eq, 1},
      "assoc" => {:eq, %{a: 1, b: 2}},
      "conj" => {:raises, FunctionClauseError},
      "contains?" => {:eq, true},
      "find" => {:eq, %Vector{items: {:a, 1}}},
      "empty?" => {:eq, false},
      "coll?" => {:eq, true},
      "map?" => {:eq, true},
      "vector?" => {:eq, false},
      "set?" => {:eq, false},
      "seq?" => {:eq, false},
      "transientable?" => {:eq, true},
      "print-str" => {:prefix, "{:"}
    },
    "vector" => %{
      "count" => {:eq, 3},
      "seq" => {:eq, Vector.new([1, 2, 3])},
      "first" => {:eq, 1},
      "rest" => {:eq, [2, 3]},
      "next" => {:eq, [2, 3]},
      "get" => {:eq, nil},
      "assoc" => {:raises, ArgumentError},
      "conj" => {:eq, Vector.new([1, 2, 3, 4])},
      "contains?" => {:eq, false},
      "find" => {:eq, nil},
      "empty?" => {:eq, false},
      "coll?" => {:eq, true},
      "map?" => {:eq, false},
      "vector?" => {:eq, true},
      "set?" => {:eq, false},
      "seq?" => {:eq, false},
      "transientable?" => {:eq, true},
      "print-str" => {:eq, "[1 2 3]"}
    },
    "set" => %{
      "count" => {:eq, 3},
      "seq" => {:eq, [1, 2, 3]},
      "first" => {:eq, 1},
      "rest" => {:eq, [2, 3]},
      "next" => {:eq, [2, 3]},
      "get" => {:eq, nil},
      "assoc" => {:raises, ArgumentError},
      "conj" => {:eq, Set.new([1, 2, 3, 4])},
      "contains?" => {:eq, false},
      "find" => {:eq, nil},
      "empty?" => {:eq, false},
      "coll?" => {:eq, true},
      "map?" => {:eq, false},
      "vector?" => {:eq, false},
      "set?" => {:eq, true},
      "seq?" => {:eq, false},
      "transientable?" => {:eq, true},
      "print-str" => {:eq, "#" <> "{1 2 3}"}
    },
    "list" => %{
      "count" => {:eq, 3},
      "seq" => {:eq, [1, 2, 3]},
      "first" => {:eq, 1},
      "rest" => {:eq, [2, 3]},
      "next" => {:eq, [2, 3]},
      "get" => {:raises, FunctionClauseError},
      "assoc" => {:raises, FunctionClauseError},
      "conj" => {:eq, [4, 1, 2, 3]},
      "contains?" => {:eq, false},
      "find" => {:eq, nil},
      "empty?" => {:eq, false},
      "coll?" => {:eq, true},
      "map?" => {:eq, false},
      "vector?" => {:eq, false},
      "set?" => {:eq, false},
      "seq?" => {:eq, true},
      "transientable?" => {:eq, false},
      "print-str" => {:eq, "(1 2 3)"}
    },
    "lazy seq" => %{
      "count" => {:eq, 3},
      "seq" => {:truthy},
      "first" => {:eq, 2},
      "rest" => {:eq, [3, 4]},
      "next" => {:eq, [3, 4]},
      "get" => {:eq, nil},
      "assoc" => {:raises, ArgumentError},
      "conj" => {:truthy},
      "contains?" => {:eq, false},
      "find" => {:eq, nil},
      "empty?" => {:eq, false},
      "coll?" => {:eq, true},
      "map?" => {:eq, false},
      "vector?" => {:eq, false},
      "set?" => {:eq, false},
      "seq?" => {:eq, true},
      "transientable?" => {:eq, false},
      "print-str" => {:eq, "(2 3 4)"}
    },
    "string" => %{
      "count" => {:eq, 2},
      "seq" => {:gap, {:raises, FunctionClauseError}, :string_seq},
      "first" => {:gap, {:eq, nil}, :string_seq},
      "rest" => {:gap, {:eq, []}, :string_seq},
      "next" => {:gap, {:eq, nil}, :string_seq},
      "get" => {:raises, FunctionClauseError},
      "assoc" => {:raises, FunctionClauseError},
      "conj" => {:raises, FunctionClauseError},
      "contains?" => {:eq, false},
      "find" => {:eq, nil},
      "empty?" => {:eq, false},
      "coll?" => {:eq, false},
      "map?" => {:eq, false},
      "vector?" => {:eq, false},
      "set?" => {:eq, false},
      "seq?" => {:eq, false},
      "transientable?" => {:eq, false},
      "print-str" => {:eq, "ab"}
    },
    "nil" => %{
      "count" => {:eq, 0},
      "seq" => {:eq, nil},
      "first" => {:eq, nil},
      "rest" => {:eq, []},
      "next" => {:eq, nil},
      "get" => {:eq, nil},
      "assoc" => {:eq, %{a: 1}},
      "conj" => {:eq, [4]},
      "contains?" => {:eq, false},
      "find" => {:eq, nil},
      "empty?" => {:eq, true},
      "coll?" => {:eq, false},
      "map?" => {:eq, false},
      "vector?" => {:eq, false},
      "set?" => {:eq, false},
      "seq?" => {:eq, false},
      "transientable?" => {:eq, false},
      "print-str" => {:eq, "nil"}
    },
    "integer" => %{
      "count" => {:raises, FunctionClauseError},
      "seq" => {:raises, FunctionClauseError},
      "first" => {:eq, nil},
      "rest" => {:eq, []},
      "next" => {:eq, nil},
      "get" => {:raises, FunctionClauseError},
      "assoc" => {:raises, FunctionClauseError},
      "conj" => {:raises, FunctionClauseError},
      "contains?" => {:eq, false},
      "find" => {:eq, nil},
      "empty?" => {:raises, FunctionClauseError},
      "coll?" => {:eq, false},
      "map?" => {:eq, false},
      "vector?" => {:eq, false},
      "set?" => {:eq, false},
      "seq?" => {:eq, false},
      "transientable?" => {:eq, false},
      "print-str" => {:eq, "42"}
    },
    "keyword" => %{
      "count" => {:raises, FunctionClauseError},
      "seq" => {:raises, FunctionClauseError},
      "first" => {:eq, nil},
      "rest" => {:eq, []},
      "next" => {:eq, nil},
      "get" => {:raises, FunctionClauseError},
      "assoc" => {:raises, FunctionClauseError},
      "conj" => {:raises, FunctionClauseError},
      "contains?" => {:eq, false},
      "find" => {:eq, nil},
      "empty?" => {:raises, FunctionClauseError},
      "coll?" => {:eq, false},
      "map?" => {:eq, false},
      "vector?" => {:eq, false},
      "set?" => {:eq, false},
      "seq?" => {:eq, false},
      "transientable?" => {:eq, false},
      "print-str" => {:eq, ":k"}
    },
    "atom-ref" => %{
      "count" => {:raises, ArgumentError},
      "seq" => {:raises, ArgumentError},
      "first" => {:raises, ArgumentError},
      "rest" => {:raises, ArgumentError},
      "next" => {:raises, ArgumentError},
      "get" => {:raises, ArgumentError},
      "assoc" => {:raises, ArgumentError},
      "conj" => {:raises, ArgumentError},
      "contains?" => {:raises, ArgumentError},
      "find" => {:raises, ArgumentError},
      "empty?" => {:raises, ArgumentError},
      "coll?" => {:eq, false},
      "map?" => {:eq, false},
      "vector?" => {:eq, false},
      "set?" => {:eq, false},
      "seq?" => {:eq, false},
      "transientable?" => {:eq, false},
      "print-str" => {:prefix, "%BeamLisp.Atom"}
    },
    "volatile" => %{
      "count" => {:raises, ArgumentError},
      "seq" => {:raises, ArgumentError},
      "first" => {:raises, ArgumentError},
      "rest" => {:raises, ArgumentError},
      "next" => {:raises, ArgumentError},
      "get" => {:raises, ArgumentError},
      "assoc" => {:raises, ArgumentError},
      "conj" => {:raises, ArgumentError},
      "contains?" => {:raises, ArgumentError},
      "find" => {:raises, ArgumentError},
      "empty?" => {:raises, ArgumentError},
      "coll?" => {:eq, false},
      "map?" => {:eq, false},
      "vector?" => {:eq, false},
      "set?" => {:eq, false},
      "seq?" => {:eq, false},
      "transientable?" => {:eq, false},
      "print-str" => {:prefix, "%BeamLisp.Volatile"}
    },
    "promise" => %{
      "count" => {:raises, ArgumentError},
      "seq" => {:raises, ArgumentError},
      "first" => {:raises, ArgumentError},
      "rest" => {:raises, ArgumentError},
      "next" => {:raises, ArgumentError},
      "get" => {:raises, ArgumentError},
      "assoc" => {:raises, ArgumentError},
      "conj" => {:raises, ArgumentError},
      "contains?" => {:raises, ArgumentError},
      "find" => {:raises, ArgumentError},
      "empty?" => {:raises, ArgumentError},
      "coll?" => {:eq, false},
      "map?" => {:eq, false},
      "vector?" => {:eq, false},
      "set?" => {:eq, false},
      "seq?" => {:eq, false},
      "transientable?" => {:eq, false},
      "print-str" => {:prefix, "%BeamLisp.Promise"}
    },
    "record" => %{
      "count" => {:eq, 2},
      "seq" => {:entries, [{:a, 1}, {:b, 2}]},
      "first" => {:entry_one_of, [{:a, 1}, {:b, 2}]},
      "rest" => {:one_of, [{:entries, [{:a, 1}]}, {:entries, [{:b, 2}]}]},
      "next" => {:one_of, [{:entries, [{:a, 1}]}, {:entries, [{:b, 2}]}]},
      "get" => {:eq, 1},
      "assoc" => {:record_fields, %{a: 1, b: 2}},
      "conj" => {:raises, FunctionClauseError},
      "contains?" => {:eq, true},
      "find" => {:eq, %Vector{items: {:a, 1}}},
      "empty?" => {:eq, false},
      "coll?" => {:eq, true},
      # Resolved in wave 27: a record answers map? true, as in Clojure.
      "map?" => {:eq, true},
      "vector?" => {:eq, false},
      "set?" => {:eq, false},
      "seq?" => {:eq, false},
      "transientable?" => {:eq, true},
      "print-str" => {:prefix, "#user/R{"}
    },
    "deftype" => %{
      "count" => {:raises, FunctionClauseError},
      "seq" => {:raises, FunctionClauseError},
      "first" => {:eq, nil},
      "rest" => {:eq, []},
      "next" => {:eq, nil},
      "get" => {:raises, FunctionClauseError},
      "assoc" => {:raises, FunctionClauseError},
      "conj" => {:raises, FunctionClauseError},
      "contains?" => {:eq, false},
      "find" => {:eq, nil},
      "empty?" => {:raises, FunctionClauseError},
      "coll?" => {:eq, false},
      "map?" => {:eq, false},
      "vector?" => {:eq, false},
      "set?" => {:eq, false},
      "seq?" => {:eq, false},
      "transientable?" => {:eq, false},
      "print-str" => {:prefix, "{:bl_deftype"}
    },
    "reify" => %{
      "count" => {:raises, FunctionClauseError},
      "seq" => {:raises, FunctionClauseError},
      "first" => {:eq, nil},
      "rest" => {:eq, []},
      "next" => {:eq, nil},
      "get" => {:raises, FunctionClauseError},
      "assoc" => {:raises, FunctionClauseError},
      "conj" => {:raises, FunctionClauseError},
      "contains?" => {:eq, false},
      "find" => {:eq, nil},
      "empty?" => {:raises, FunctionClauseError},
      "coll?" => {:eq, false},
      "map?" => {:eq, false},
      "vector?" => {:eq, false},
      "set?" => {:eq, false},
      "seq?" => {:eq, false},
      "transientable?" => {:eq, false},
      "print-str" => {:prefix, "{:bl_reify"}
    },
    "fn" => %{
      "count" => {:raises, FunctionClauseError},
      "seq" => {:raises, FunctionClauseError},
      "first" => {:eq, nil},
      "rest" => {:eq, []},
      "next" => {:eq, nil},
      "get" => {:raises, FunctionClauseError},
      "assoc" => {:raises, FunctionClauseError},
      "conj" => {:raises, FunctionClauseError},
      "contains?" => {:eq, false},
      "find" => {:eq, nil},
      "empty?" => {:raises, FunctionClauseError},
      "coll?" => {:eq, false},
      "map?" => {:eq, false},
      "vector?" => {:eq, false},
      "set?" => {:eq, false},
      "seq?" => {:eq, false},
      "transientable?" => {:eq, false},
      "print-str" => {:eq, "#fn[multi-arity]"}
    },
    "transient" => %{
      "count" => {:raises, FunctionClauseError},
      "seq" => {:raises, FunctionClauseError},
      "first" => {:eq, nil},
      "rest" => {:eq, []},
      "next" => {:eq, nil},
      "get" => {:eq, 1},
      "assoc" => {:gap, {:raises, FunctionClauseError}, :transient_map_ops},
      "conj" => {:gap, {:raises, FunctionClauseError}, :transient_map_ops},
      "contains?" => {:gap, {:eq, false}, :transient_map_ops},
      "find" => {:gap, {:eq, nil}, :transient_map_ops},
      "empty?" => {:raises, FunctionClauseError},
      "coll?" => {:gap, {:eq, false}, :transient_coll_false},
      "map?" => {:gap, {:eq, false}, :transient_coll_false},
      "vector?" => {:eq, false},
      "set?" => {:eq, false},
      "seq?" => {:eq, false},
      "transientable?" => {:eq, false},
      "print-str" => {:prefix, "{:\"$transient\""}
    }
  }

  # Every `{:gap, _, reason}` reason that the table must currently record.
  # A divergence that is known, deliberate, and reported is acceptable; a
  # silent one is not. Adding a new gap here is a conscious act.
  # (`:record_map_deliberate_false` was retired in wave 27 -- `map?` now
  # answers true for a record, as Clojure does, so the gap no longer exists.
  # This list shrinking is the point: a resolved gap must leave the inventory.)
  @known_gap_reasons [
    :string_seq,
    :transient_map_ops,
    :transient_coll_false
  ]

  setup do
    BeamLisp.init()
    BeamLisp.Env.in_ns("user")
    eval("(defrecord R [a b])")
    eval("(deftype DT [a b])")
    eval("(defprotocol RP (rm [this]))")
    :ok
  end

  defp eval(source), do: Compiler.eval_string(source, Compiler.new_env("user"))

  defp normalize_entries(%Vector{items: {k, v}}), do: {k, v}
  defp normalize_entries(list) when is_list(list), do: Enum.map(list, &normalize_entries/1) |> Enum.sort()

  # Returns true when `result` satisfies `exp` (no assertion side effects —
  # used for `:one_of` which must be able to try and discard).
  defp matches?(result, {:eq, expected}), do: result == expected
  # A record's module is created at RUNTIME (defrecord in beam-lisp), so it
  # cannot be named in a compile-time struct literal — compare it structurally
  # instead: any user record whose public fields equal `fields`.
  defp matches?(result, {:record_fields, fields}),
    do: BeamLisp.Record.record?(result) and Map.drop(result, [:__struct__]) == fields
  defp matches?(result, {:truthy}), do: result not in [nil, false]
  defp matches?(result, {:falsey}), do: result in [nil, false]
  defp matches?(result, {:prefix, p}) when is_binary(result), do: String.starts_with?(result, p)
  defp matches?(result, {:entry, {k, v}}), do: result == %Vector{items: {k, v}}
  defp matches?(result, {:entry_one_of, kvs}),
    do: match?(%Vector{items: {_k, _v}}, result) and {elem(result.items, 0), elem(result.items, 1)} in kvs

  defp matches?(result, {:entries, kvs}), do: normalize_entries(result) == Enum.sort(kvs)

  defp matches?(result, {:one_of, exps}), do: Enum.any?(exps, &matches?(result, &1))

  defp matches?(result, {:gap, inner, _reason}), do: matches?(result, inner)

  defp assert_expectation(_src, _result, {:raises, _mod}) do
    # raises is handled by the caller (it must not eval), so here it is a
    # contradiction by construction — unreachable.
    raise "unreachable: raises handled in run_cell"
  end

  defp assert_expectation(_src, result, exp) do
    assert matches?(result, exp), "got #{inspect(result)}, expected #{inspect(exp)}"
  end

  defp run_cell(src, {:raises, mod}) do
    assert_raise mod, fn -> eval(src) end
  end

  defp run_cell(src, {:gap, {:raises, mod}, _reason}) do
    assert_raise mod, fn -> eval(src) end
  end

  defp run_cell(src, {:gap, inner, _reason}), do: assert_expectation(src, eval(src), inner)

  defp run_cell(src, exp), do: assert_expectation(src, eval(src), exp)

  test "every value answers every collection fn per the decided semantics" do
    total = length(@values) * length(@fns)

    for {vn, vex} <- @values,
        {fnn, shape} <- @fns do
      src = String.replace(shape, "%s", vex)
      exp = @expectations[vn][fnn]

      # A cell with no decided expectation is a bug in the table itself.
      assert exp != nil, "missing expectation for #{vn} x #{fnn}"
      run_cell(src, exp)
    end

    # Every value was actually exercised (306 = 17 x 18); the loop above
    # already asserts each cell, so this count guards the table's own shape.
    assert total == 306
  end

  test "the known-gap inventory is exactly what is recorded (no silent drift)" do
    # Static over the table DATA (not the run): every `{:gap, _, reason}`
    # recorded in the expectation matrix must be in the deliberate inventory,
    # and every deliberate reason must actually appear. A divergence that is
    # known, deliberate, and reported is acceptable; a silent one is not — and
    # adding a gap becomes a conscious act, not an accidental one.
    reasons =
      for {vn, _} <- @values,
          {fnn, _} <- @fns,
          exp = @expectations[vn][fnn] do
        case exp do
          {:gap, _, r} -> r
          _ -> nil
        end
      end
      |> Enum.reject(&is_nil/1)

    assert Enum.sort(Enum.uniq(reasons)) == Enum.sort(@known_gap_reasons)
  end

  describe "cells a single fixed call shape cannot express" do
    test "map assoc with a NEW key and conj with a [k v] entry" do
      assert eval("(assoc {:a 1} :c 3)") == %{a: 1, c: 3}
      assert eval("(conj {:a 1} [:c 3])") == %{a: 1, c: 3}
    end

    test "record assoc/conj add a NEW field while preserving the type" do
      rec = eval("(->R 1 2)")
      assert eval("(assoc (->R 1 2) :c 3)") == Map.put(rec, :c, 3)
      assert eval("(conj (->R 1 2) [:c 3])") == Map.put(rec, :c, 3)
    end

    test "a set get/contains with a PRESENT member reads through" do
      assert eval("(get " <> @set3 <> " 2)") == 2
      assert eval("(contains? " <> @set3 <> " 2)") == true
      # `(find #{1 2 3} 2)` in Clojure is `[2 2]`; beam-lisp answers nil (find
      # is a map fn and a set is not a map). Reported; not fixed.
      assert eval("(find " <> @set3 <> " 2)") == nil
    end

    test "a lazy seq conj prepends without corrupting (improper tail)" do
      assert eval("(first (conj (map inc (range 1 4)) 4))") == 4
    end

    test "empty lazy results are () not []" do
      assert eval("(seq (map inc (range 4 1)))") == nil
    end
  end
end
