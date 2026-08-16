defmodule BeamLisp.WatchesTest do
  @moduledoc """
  `add-watch` / `remove-watch`, and the `spell.st` connector built on them
  (verse PLAN-148 W6).

  Before this, atoms supported `deref` / `swap!` / `reset!` /
  `compare-and-set!` but nothing could OBSERVE a change — a genuine
  Clojure-compat hole, and the one primitive standing between an atom and an
  automatic UI connector where an ordinary `swap!` drives the browser.
  """

  use ExUnit.Case, async: false

  defp eval(source), do: BeamLisp.eval(source)

  defp realize_pairs(%BeamLisp.Vector{items: items}),
    do: items |> Tuple.to_list() |> Enum.map(&realize_pairs/1)

  defp realize_pairs(other), do: other

  describe "add-watch / remove-watch" do
    test "a watch sees every change, with old and new" do
      result =
        eval("""
        (def a (atom {:n 0}))
        (def seen (atom []))
        (add-watch a :k (fn [_k _r old new]
                          (swap! seen conj [(get old :n) (get new :n)])))
        (swap! a assoc :n 1)
        (swap! a assoc :n 2)
        @seen
        """)

      assert realize_pairs(result) == [[0, 1], [1, 2]]
    end

    test "reset! notifies too, not only swap!" do
      result =
        eval("""
        (def a (atom 1))
        (def seen (atom []))
        (add-watch a :k (fn [_k _r old new] (swap! seen conj [old new])))
        (reset! a 9)
        @seen
        """)

      assert realize_pairs(result) == [[1, 9]]
    end

    test "remove-watch stops notifications" do
      result =
        eval("""
        (def a (atom 0))
        (def seen (atom []))
        (add-watch a :k (fn [_k _r _old new] (swap! seen conj new)))
        (reset! a 1)
        (remove-watch a :k)
        (reset! a 2)
        [@seen @a]
        """)

      assert realize_pairs(result) == [[1], 2]
    end

    test "the watch receives its own key, so one fn can serve several" do
      result =
        eval("""
        (def a (atom 0))
        (def seen (atom []))
        (add-watch a :one (fn [k _r _o _n] (swap! seen conj k)))
        (add-watch a :two (fn [k _r _o _n] (swap! seen conj k)))
        (reset! a 1)
        @seen
        """)

      assert Enum.sort(realize_pairs(result)) == [:one, :two]
    end

    test "swap! still returns the new value" do
      assert eval("(let [a (atom 1)] (swap! a inc))") == 2
    end

    test "reset! still returns the value it set" do
      assert eval("(let [a (atom 1)] (reset! a 7))") == 7
    end

    test "an unwatched atom behaves exactly as before" do
      # The zero-change guarantee for the existing surface: adding watches must
      # not alter an atom that has none.
      assert eval("(let [a (atom 1)] (swap! a + 2) @a)") == 3
      assert eval("(let [a (atom 1)] (compare-and-set! a 1 5))") == true
      assert eval("(let [a (atom 1)] (compare-and-set! a 9 5) @a)") == 1
    end

    test "add-watch on a non-atom is a named error" do
      assert_raise ArgumentError, ~r/add-watch/, fn ->
        eval("(add-watch 42 :k (fn [_k _r _o _n] nil))")
      end
    end
  end

  describe "spell.st connector" do
    defp connector(body), do: eval(File.read!("spell/study/spell/st.bl") <> "\n" <> body)

    test "an ordinary swap! pushes the declared signals" do
      result =
        connector("""
        (def state (atom {:messages [] :status "idle"}))
        (connect! state {:messages '$messages :status '$status})
        (swap! state assoc :status "thinking")
        (pushed)
        """)

      assert realize_pairs(result) == [[{:symbol, "$status"}, "thinking"]]
    end

    test "only CHANGED declared keys push" do
      # The reason the diff lives in the connector: an atom carrying many fields
      # where one moved must send one update, not many.
      result =
        connector("""
        (def state (atom {:a 1 :b 2 :untracked 0}))
        (connect! state {:a '$a :b '$b})
        (swap! state assoc :a 9)
        (pushed)
        """)

      assert realize_pairs(result) == [[{:symbol, "$a"}, 9]]
    end

    test "an undeclared key never pushes" do
      result =
        connector("""
        (def state (atom {:a 1 :untracked 0}))
        (connect! state {:a '$a})
        (swap! state assoc :untracked 42)
        (pushed)
        """)

      assert realize_pairs(result) == []
    end

    test "re-setting the same value pushes nothing" do
      result =
        connector("""
        (def state (atom {:a 1}))
        (connect! state {:a '$a})
        (swap! state assoc :a 1)
        (pushed)
        """)

      assert realize_pairs(result) == []
    end

    test "disconnect! stops the pushes" do
      result =
        connector("""
        (def state (atom {:a 1}))
        (connect! state {:a '$a})
        (swap! state assoc :a 2)
        (disconnect! state)
        (swap! state assoc :a 3)
        [(pushed) @state]
        """)

      [pushes, final] = realize_pairs(result)
      assert pushes == [[{:symbol, "$a"}, 2]]
      assert final == %{a: 3}
    end

    test "the inbound cycle closes with no UI code in the handler" do
      # browser signal → handler → swap! → watch → push. The handler mutates
      # state and nothing else; the interface update is a consequence.
      result =
        connector("""
        (def state (atom {:messages [] :status "idle"}))
        (connect! state {:messages '$messages :status '$status})
        (on :send (fn [payload]
                    (swap! state assoc :messages [(get payload :body)])
                    (swap! state assoc :status "thinking")))
        (def ran (dispatch! :send {:body "hello"}))
        [ran (pushed)]
        """)

      [ran, pushes] = realize_pairs(result)
      assert ran == true

      assert pushes == [
               [{:symbol, "$messages"}, ["hello"]],
               [{:symbol, "$status"}, "thinking"]
             ]
    end

    test "an unknown inbound signal reports false rather than raising" do
      assert connector("""
             (def state (atom {}))
             (dispatch! :nobody-listens {})
             """) == false
    end
  end
end
