defmodule BeamLisp.Wave14MetaTest do
  use ExUnit.Case, async: false

  alias BeamLisp.{Env, LazySeq, Meta, RT, Vector}

  setup do
    BeamLisp.init()
    Env.in_ns("user")
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  # A lazy seq is the one value type with genuine per-instance identity
  # on the BEAM (its realization `:key` reference), so it is the value
  # type that actually carries metadata.
  defp seq1, do: LazySeq.new(fn -> [1, 2, 3] end)

  describe "BeamLisp.Meta on lazy seqs" do
    test "absent metadata reads as nil, not an empty map" do
      assert Meta.meta(seq1()) == nil
    end

    test "with_meta attaches and meta reads it back" do
      tagged = Meta.with_meta(seq1(), %{doc: "three numbers"})
      assert Meta.meta(tagged) == %{doc: "three numbers"}
    end

    test "with_meta returns a NEW value; the original keeps its own metadata" do
      original = seq1()
      tagged = Meta.with_meta(original, %{a: 1})
      assert tagged != original
      assert Meta.meta(original) == nil
      assert Meta.meta(tagged) == %{a: 1}
    end

    test "the tagged value is still equal to the original (metadata not in =)" do
      original = seq1()
      tagged = Meta.with_meta(original, %{a: 1})
      assert RT.eqv(original, tagged)
    end

    test "the tagged value still realizes to the same elements" do
      tagged = Meta.with_meta(seq1(), %{a: 1})
      assert LazySeq.to_list(tagged) == [1, 2, 3]
    end

    test "printing is unaffected (metadata never appears in inspect)" do
      plain = seq1()
      tagged = Meta.with_meta(plain, %{doc: "secret", a: [1, 2]})
      assert inspect(tagged) == inspect(plain)
    end

    test "with_meta replaces prior metadata" do
      tagged = Meta.with_meta(seq1(), %{a: 1})
      replaced = Meta.with_meta(tagged, %{b: 2})
      assert Meta.meta(replaced) == %{b: 2}
      # the first tagged node is untouched
      assert Meta.meta(tagged) == %{a: 1}
    end

    test "nil metadata clears (reads back as nil)" do
      tagged = Meta.with_meta(seq1(), %{a: 1})
      assert Meta.meta(Meta.with_meta(tagged, nil)) == nil
    end

    test "vary_meta folds the current metadata through an Elixir function" do
      tagged = Meta.with_meta(seq1(), %{a: 1})
      bumped = Meta.vary_meta(tagged, fn m -> Map.put(m, :b, 2) end)
      assert Meta.meta(bumped) == %{a: 1, b: 2}
    end

    test "vary_meta passes nil to the function when metadata is absent" do
      bumped = Meta.vary_meta(seq1(), fn m -> Map.put(m || %{}, :k, 1) end)
      assert Meta.meta(bumped) == %{k: 1}
    end

    test "vary_meta accepts a beam-lisp fn value" do
      tagged = Meta.with_meta(seq1(), %{doc: "d"})
      f = eval("(fn [m] (assoc (or m {}) :tagged true))")
      assert Meta.meta(Meta.vary_meta(tagged, f)) == %{doc: "d", tagged: true}
    end
  end

  describe "BeamLisp.Meta on value-typed values (documented no-op)" do
    test "meta is nil and with_meta returns the value unchanged" do
      values = [
        [1, 2, 3],
        %{a: 1},
        Vector.new([1, 2]),
        42,
        "hello",
        :kw,
        {:symbol, "x"}
      ]

      for v <- values do
        assert Meta.meta(v) == nil, "meta of #{inspect(v)} should be nil"
        assert Meta.with_meta(v, %{doc: "d"}) === v,
               "with_meta on #{inspect(v)} should be a no-op"
      end
    end

    test "non-map metadata is rejected" do
      assert_raise ArgumentError, ~r/metadata must be a map or nil/, fn ->
        Meta.with_meta(seq1(), "not a map")
      end
    end

    test "value metadata is reachable by slash interop" do
      tagged =
        eval(
          ~s|(BeamLisp.Meta/with_meta (BeamLisp.LazySeq/from_fun (fn [] (list 1 2))) {:doc "via interop"})|
        )

      assert LazySeq.to_list(tagged) == [1, 2]
      # meta/1 through the module reads it back
      assert Meta.meta(tagged) == %{doc: "via interop"}
    end
  end

  describe "var metadata (general map, merge semantics)" do
    test "put_meta stores a general map" do
      Env.put_meta("user", "w14-general", %{private: true})
      assert Env.meta("user", "w14-general") == {:ok, %{private: true}}
    end

    test "put_meta merges: doc and private coexist" do
      Env.put_meta("user", "w14-merge", %{doc: "first"})
      Env.put_meta("user", "w14-merge", %{private: true})
      assert Env.meta("user", "w14-merge") == {:ok, %{doc: "first", private: true}}
    end

    test "merge keeps earlier keys across a redefinition, latest value wins per key" do
      Env.put_meta("user", "w14-redef", %{doc: "old", dynamic: true})
      Env.put_meta("user", "w14-redef", %{doc: "new"})
      assert Env.meta("user", "w14-redef") == {:ok, %{doc: "new", dynamic: true}}
    end

    test "a defn's docstring and a later metadata write merge" do
      eval(~s|(defn w14-doc "Squares n." [n] (* n n))|)
      assert Env.meta("user", "w14-doc") == {:ok, %{doc: "Squares n."}}
      Env.put_meta("user", "w14-doc", %{private: true})
      assert Env.meta("user", "w14-doc") == {:ok, %{doc: "Squares n.", private: true}}
    end

    test "doc_string still resolves the docstring from a merged map" do
      eval(~s|(defn w14-ds "Docs." [x] x)|)
      Env.put_meta("user", "w14-ds", %{dynamic: true})
      assert Env.doc_string("user", "w14-ds") == %{ns: "user", name: "w14-ds", doc: "Docs."}
    end

    test "doc_string resolves through the core fallback after a merge" do
      assert Env.doc_string("user", "zipmap") ==
               %{ns: "core", name: "zipmap", doc: "Builds a map from parallel keys and values."}
    end

    test "doc_string resolves a referred var" do
      Env.add_refer("user", "w14-referred", "w14-other")
      Env.put_meta("w14-other", "w14-referred", %{doc: "referred docs"})
      assert Env.doc_string("user", "w14-referred") ==
               %{ns: "w14-other", name: "w14-referred", doc: "referred docs"}
    end
  end
end
