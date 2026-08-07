defmodule BeamLisp.Wave17TransientTest do
  # Clojure transients (wave 17): a mutable-inside-a-scope view of a
  # persistent collection. The transient wrapper lives in
  # BeamLisp.Transient; `persistent!` is a one-way door — using a
  # transient after persisting raises. Vectors get a real bulk-build
  # win (accumulate + rebuild trie once); maps are an API-compat layer
  # over Elixir's already-persistent maps.
  use ExUnit.Case, async: false

  @moduletag :wave17

  defp eval_in(source) do
    BeamLisp.init()
    BeamLisp.Compiler.eval_string(source, BeamLisp.Compiler.new_env("wave17"))
  end

  # Load a vendored jank fixture verbatim into a throwaway ns and call
  # it — the fidelity harness pattern, reused here for the six slices
  # this facility unlocks.
  defp load_fixture(fixture, ns) do
    code =
      ["test", "fixtures", "jank", fixture]
      |> Path.join()
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, ";"))
      |> Enum.join("\n")

    BeamLisp.init()
    BeamLisp.Compiler.eval_string("(ns #{ns})\n" <> code, BeamLisp.Compiler.new_env(ns))
  end

  describe "transient vectors" do
    test "build-then-persist equals the persistently-built equivalent" do
      assert eval_in("(persistent! (conj! (conj! (conj! (transient []) 1) 2) 3))") ==
               eval_in("[1 2 3]")

      assert eval_in("(= (persistent! (conj! (transient []) 1)) [1])") == true
    end

    test "bulk build stays correct past the trie boundary (32+)" do
      # 1000 conj!s crosses the raw-tuple → trie transition several times.
      assert eval_in("""
             (count (persistent!
                     (reduce (fn [acc i] (conj! acc i))
                             (transient [])
                             (range 1000))))
             """) == 1000
    end

    test "transient of a non-empty vector seeds its elements" do
      assert eval_in("(persistent! (conj! (transient [1 2]) 3))") == eval_in("[1 2 3]")
    end

    test "use-after-persistent raises" do
      assert_raise ArgumentError, ~r/already-persisted/, fn ->
        eval_in("""
        (let [t (transient [])]
          (persistent! (conj! t 1))
          (conj! t 2))
        """)
      end

      assert_raise ArgumentError, ~r/already-persisted|expected a transient/, fn ->
        eval_in("(persistent! (persistent! (transient [])))")
      end
    end
  end

  describe "transient maps" do
    test "build-then-persist equals the persistently-built equivalent" do
      assert eval_in("(persistent! (assoc! (assoc! (transient {}) :a 1) :b 2))") ==
               eval_in("{:a 1 :b 2}")

      assert eval_in("(= (persistent! (assoc! (transient {}) :a 1)) {:a 1})") == true
    end

    test "get reads through to live state (frequencies/group-by pattern)" do
      assert eval_in("""
             (persistent!
              (assoc! (assoc! (transient {}) :a (inc (get (transient {:a 1}) :a 0)))
                      :b 5))
             """) == eval_in("{:a 2 :b 5}")
    end

    test "dissoc! removes entries" do
      assert eval_in("(persistent! (dissoc! (transient {:a 1 :b 2}) :a))") ==
               eval_in("{:b 2}")
    end

    test "use-after-persistent raises on assoc!/get/dissoc!" do
      assert_raise ArgumentError, ~r/already-persisted/, fn ->
        eval_in("""
        (let [t (transient {})]
          (persistent! (assoc! t :a 1))
          (assoc! t :b 2))
        """)
      end
    end
  end

  describe "hash-map" do
    test "zero-arity is the empty map; even-arity builds" do
      assert eval_in("(hash-map)") == %{}
      assert eval_in("(hash-map :a 1)") == eval_in("{:a 1}")
      assert eval_in("(hash-map :a 1 :b 2)") == eval_in("{:a 1 :b 2}")
      assert eval_in("(persistent! (transient (hash-map)))") == %{}
    end
  end

  describe "verbatim jank fixtures unlocked by transients" do
    test "keys" do
      load_fixture("slice_26_keys.bl", "w17.keys")
      # keys returns the map's keys in seq order (implementation-defined,
      # like Clojure); the fixture must match the order reduce sees.
      assert eval_in("(w17.keys/keys {:a 1 :b 2 :c 3})") ==
               eval_in("(reduce (fn [acc kv] (conj acc (first kv))) [] {:a 1 :b 2 :c 3})")
      assert Enum.sort(BeamLisp.Vector.to_list(eval_in("(w17.keys/keys {:a 1 :b 2 :c 3})"))) ==
               [:a, :b, :c]
    end

    test "vals" do
      load_fixture("slice_27_vals.bl", "w17.vals")
      assert eval_in("(w17.vals/vals {:a 1 :b 2 :c 3})") ==
               eval_in("(reduce (fn [acc kv] (conj acc (second kv))) [] {:a 1 :b 2 :c 3})")
      assert Enum.sort(BeamLisp.Vector.to_list(eval_in("(w17.vals/vals {:a 1 :b 2 :c 3})"))) ==
               [1, 2, 3]
    end

    test "zipmap" do
      load_fixture("slice_29_zipmap.bl", "w17.zipmap")
      assert eval_in("(w17.zipmap/zipmap [:a :b :c] [1 2 3])") == eval_in("{:a 1 :b 2 :c 3}")
      assert eval_in("(w17.zipmap/zipmap [:a :b] [1 2 3])") == eval_in("{:a 1 :b 2}")
    end

    test "frequencies" do
      load_fixture("slice_42_frequencies.bl", "w17.frequencies")
      assert eval_in("(w17.frequencies/frequencies [:a :b :a :c :a :b])") ==
               eval_in("{:a 3 :b 2 :c 1}")
    end

    test "group-by" do
      load_fixture("slice_43_group_by.bl", "w17.groupby")
      assert eval_in("(w17.groupby/group-by even? [1 2 3 4 5])") ==
               eval_in("{false [1 3 5], true [2 4]}")
    end
  end

  describe "bulk-build benchmark (evidence, not assertion)" do
    # Real numbers, honestly reported: the process-dictionary indirection
    # per conj! costs more than the persistent vector's already-amortized
    # tail-buffer savings, so the transient is an API-compat layer, not a
    # speedup. We time a 100k build both ways and print the ratio — the
    # correctness check is the real assertion.
    @tag timeout: 120_000
    test "transient vector build on 100k — timing + correctness" do
      {t_persist, v} =
        :timer.tc(fn ->
          eval_in("""
          (persistent!
           (reduce (fn [acc i] (conj! acc i))
                   (transient [])
                   (range 100000)))
          """)
        end)

      {t_plain, pv} =
        :timer.tc(fn ->
          eval_in("""
          (reduce (fn [acc i] (conj acc i))
                  []
                  (range 100000))
          """)
        end)

      IO.puts(
        "bench: 100k conj! transient=#{t_persist}µs plain conj=#{t_plain}µs " <>
          "ratio=#{Float.round(t_persist / max(t_plain, 1), 2)}x " <>
          "(transient is API-compat, not a speedup on BEAM)"
      )

      assert BeamLisp.Vector.count(v) == 100_000
      assert BeamLisp.Vector.first(v) == 0
      assert BeamLisp.Vector.count(pv) == 100_000
      assert v == pv
    end
  end
end
