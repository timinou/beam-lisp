defmodule BeamLisp.SourceGraphTest do
  # The graph is beam-lisp code (priv/build/source-graph.bl): the runtime must
  # be up. `async: false` because `init/0` seeds the VM-wide Env.
  use ExUnit.Case, async: false

  alias BeamLisp.SourceGraph

  setup_all do
    BeamLisp.init()
    :ok
  end

  describe "header/1" do
    test "ns with no requires" do
      assert {"core", []} = SourceGraph.header("(ns core)\n(defn f [] 1)")
    end

    test "ns with :as and bare require specs" do
      src = "(ns compiler\n  (:require [reader-node :as rn] [other]))\n(defn g [] 2)"
      assert {"compiler", requires} = SourceGraph.header(src)
      assert Enum.sort(requires) == ["other", "reader-node"]
    end

    test "no ns form yields {nil, []}" do
      assert {nil, []} = SourceGraph.header("(defn f [] 1)")
    end

    test "a :require mentioned in a COMMENT is not an edge" do
      # The exact trap: raw-text scanning would read `datom` as a dependency.
      src = """
      (ns interop)
      ; the same way `datom` is required via (:require [datom]) elsewhere
      (defn h [] 3)
      """

      assert {"interop", []} = SourceGraph.header(src)
    end

    test ":refer list members are not taken as requires" do
      src = "(ns a (:require [b :refer [x y]]))"
      assert {"a", ["b"]} = SourceGraph.header(src)
    end

    test "a ; inside a string literal does not truncate the form" do
      src = ~S|(ns a (:require [b]))
      (def s "has ; semicolon")|
      assert {"a", ["b"]} = SourceGraph.header(src)
    end
  end

  describe "cycles/2" do
    test "an acyclic graph has none" do
      reqs = fn n -> %{"a" => ["b"], "b" => []} |> Map.get(n, []) end
      assert SourceGraph.cycles(["a"], reqs) == []
    end

    test "a two-node cycle is named as a closed path" do
      reqs = fn n -> %{"x" => ["y"], "y" => ["x"]} |> Map.get(n, []) end
      assert SourceGraph.cycles(["x"], reqs) == [["x", "y", "x"]]
    end

    test "the BUG-064 shape: a four-node substrate/application cycle" do
      reqs = fn n ->
        %{
          "vm.session" => ["bl.daemon"],
          "bl.daemon" => ["bl.cli"],
          "bl.cli" => ["vm.client"],
          "vm.client" => ["vm.session"]
        }
        |> Map.get(n, [])
      end

      assert [cycle] = SourceGraph.cycles(["bl.cli"], reqs)
      assert hd(cycle) == List.last(cycle)
      assert Enum.sort(Enum.drop(cycle, -1)) == ["bl.cli", "bl.daemon", "vm.client", "vm.session"]
    end

    test "a cycle off the spine of an acyclic root is still found" do
      reqs = fn n -> %{"a" => ["b", "c"], "b" => [], "c" => ["d"], "d" => ["c"]} |> Map.get(n, []) end
      assert SourceGraph.cycles(["a"], reqs) == [["c", "d", "c"]]
    end

    test "a self-require is a cycle of one" do
      reqs = fn n -> %{"a" => ["a"]} |> Map.get(n, []) end
      assert SourceGraph.cycles(["a"], reqs) == [["a", "a"]]
    end

    test "an unresolvable require is skipped, not crashed on" do
      reqs = fn n -> %{"a" => ["missing"]} |> Map.get(n, []) end
      assert SourceGraph.cycles(["a"], reqs) == []
    end
  end

  describe "closure/2 and closure_hash/3" do
    # a -> b -> c ; a -> d
    @reqs %{"a" => ["b", "d"], "b" => ["c"], "c" => [], "d" => []}

    test "closure is transitive and includes self" do
      reqs = fn n -> Map.get(@reqs, n, []) end
      assert SourceGraph.closure("a", reqs) |> Enum.sort() == ["a", "b", "c", "d"]
      assert SourceGraph.closure("b", reqs) |> Enum.sort() == ["b", "c"]
    end

    test "closure is cycle-safe" do
      reqs = fn n -> %{"x" => ["y"], "y" => ["x"]} |> Map.get(n, []) end
      assert SourceGraph.closure("x", reqs) |> Enum.sort() == ["x", "y"]
    end

    test "hash changes iff a closure member's source hash changes" do
      reqs = fn n -> Map.get(@reqs, n, []) end
      h = fn hashes -> SourceGraph.closure_hash("a", &Map.get(hashes, &1), reqs) end

      base = %{"a" => "1", "b" => "1", "c" => "1", "d" => "1"}
      # changing c (a transitive dep of a) changes a's hash
      refute h.(base) == h.(%{base | "c" => "2"})
      # changing an unrelated ns not in a's closure does not
      assert h.(base) == h.(Map.put(base, "z", "9"))
    end

    test "an unresolvable member is a distinct, stable contribution" do
      reqs = fn n -> %{"a" => ["missing"]} |> Map.get(n, []) end
      # missing → srchash nil → rendered as "missing:?" ; stable across calls
      h1 = SourceGraph.closure_hash("a", fn _ -> nil end, reqs)
      h2 = SourceGraph.closure_hash("a", fn _ -> nil end, reqs)
      assert h1 == h2
    end
  end
end
