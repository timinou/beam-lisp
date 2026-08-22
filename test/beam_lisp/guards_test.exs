defmodule BeamLisp.GuardsTest do
  # Guards and clause dispatch: the half of Elixir's quoted format that
  # beam-lisp could always express but never offered a spelling for.
  #
  # Three facts drove this wave:
  #
  #   1. `defserver` and `receive` already compiled PATTERNS into real
  #      Elixir clause heads — but nothing could say what must be TRUE of
  #      the values a pattern bound, so every validity test moved into the
  #      body, where it can no longer decline the message.
  #   2. `(defn f [x] :when (int? x) …)` COMPILED, and applied no guard:
  #      `:when` was read as a body form, evaluated to itself, discarded.
  #      Silence on a construct the author obviously meant.
  #   3. Two same-arity clauses were not an error either. `$blfn` keyed
  #      its dispatch map by arity, so the second silently replaced the
  #      first — dead code that looked live.
  #
  # A guard is a RESTRICTED dialect on every BEAM language (the VM
  # evaluates it without calling user code), so the tests below pin both
  # halves: what a guard can express, and that everything else is refused
  # BY NAME at compile time rather than crashing inside generated Elixir.
  use ExUnit.Case, async: false

  @moduletag :guards

  defp eval(ns, source) do
    BeamLisp.init()
    BeamLisp.Compiler.eval_string(source, BeamLisp.Compiler.new_env(ns))
  end

  defp compile_error(ns, source) do
    assert_raise BeamLisp.CompileError, fn -> eval(ns, source) end
  end

  # ── defn / fn clause dispatch ──────────────────────────────────────

  test "same-arity clauses are chosen by their guards, not silently dropped" do
    assert eval("gd1", """
           (defn classify
             ([x] :when (int? x) :integer)
             ([x] :when (string? x) :string)
             ([x] :other))
           (list (classify 1) (classify "a") (classify :k))
           """) == [:integer, :string, :other]
  end

  test "an anonymous fn dispatches on guards too" do
    assert eval("gd2", """
           (def f (fn ([x] :when (pos? x) :pos) ([x] :nonpos)))
           (list (f 3) (f -3) (f 0))
           """) == [:pos, :nonpos, :nonpos]
  end

  test "guards compose with multi-arity dispatch" do
    assert eval("gd3", """
           (defn f
             ([x] :when (int? x) :one-int)
             ([x] :one-other)
             ([x y] :two))
           (list (f 1) (f :k) (f 1 2))
           """) == [:"one-int", :"one-other", :two]
  end

  # Clojure conventionally writes arities in ascending order but nothing
  # enforces it. Grouping by ADJACENCY would put these two `[x]` clauses
  # in separate groups and lose the first — the exact bug this wave fixed,
  # reintroduced for anyone who interleaved.
  test "same-arity clauses need not be adjacent" do
    assert eval("gd4", """
           (defn f
             ([x] :when (int? x) :one-int)
             ([x y] :two)
             ([x] :one-other))
           (list (f 1) (f :k) (f 1 2))
           """) == [:"one-int", :"one-other", :two]
  end

  # `recur` re-enters the DISPATCHER, so a recur whose new arguments fail
  # this clause's guard lands in the next clause. That is what lets a
  # guarded loop terminate by falling through rather than by testing the
  # base case twice.
  test "recur crosses a guard boundary into the next clause" do
    assert eval("gd5", """
           (defn countdown
             ([n] :when (pos? n) (recur (- n 1)))
             ([n] [:done n]))
           (countdown 5)
           """) == %BeamLisp.Vector{items: {:done, 0}}
  end

  test "a guarded fn still works through invoke (apply / map / interop)" do
    assert eval("gd6", """
           (defn sign
             ([n] :when (pos? n) :+)
             ([n] :when (neg? n) :-)
             ([_n] :zero))
           (to-list (map sign [3 -3 0]))
           """) == [:+, :-, :zero]
  end

  test "a variadic clause coexists with guarded fixed clauses" do
    assert eval("gd7", """
           (defn f
             ([x] :when (int? x) :int)
             ([x] :other)
             ([x & more] [:many (count more)]))
           (list (f 1) (f :k) (f 1 2 3))
           """) == [:int, :other, %BeamLisp.Vector{items: {:many, 2}}]
  end

  # ── receive ────────────────────────────────────────────────────────

  # The point of a guard in a receive is NOT that it filters: it is that a
  # non-matching message is never received, so it stays in the mailbox for
  # a later clause. An `if` in the body cannot do this — the message is
  # already consumed by then.
  test "a receive guard leaves non-matching messages in the mailbox" do
    assert eval("gr1", """
           (erlang/send (erlang/self) [:take 5])
           (erlang/send (erlang/self) [:take -1])
           (let [neg (receive [:take n] :when (neg? n) n (after 200 :timeout))
                 pos (receive [:take n] :when (pos? n) n (after 200 :timeout))]
             (list neg pos))
           """) == [-1, 5]
  end

  test "a receive clause without a guard is unchanged" do
    assert eval("gr2", """
           (erlang/send (erlang/self) :ping)
           (receive :ping :pong (after 200 :timeout))
           """) == :pong
  end

  # ── nested patterns (BUG-002) ──────────────────────────────────────

  # A vector pattern matches an Erlang tuple AND a beam-lisp vector, so it
  # yields two clause shapes. Nesting MULTIPLIES them, and the compiler
  # used to assume exactly one — crashing with a raw MatchError from its
  # own internals the moment a vector held a vector.
  test "nested vector patterns compile and match (BUG-002)" do
    assert eval("gn1", """
           (erlang/send (erlang/self) [:a [:b 1]])
           (receive [:a [:b n]] n (after 200 :timeout))
           """) == 1
  end

  test "nesting works at depth 3 and through a map" do
    assert eval("gn2", """
           (erlang/send (erlang/self) [:a [:b [:c 7]]])
           (receive [:a [:b [:c n]]] n (after 200 :timeout))
           """) == 7

    assert eval("gn3", """
           (erlang/send (erlang/self) {:k [:x [:y 2]]})
           (receive {:k [:x [:y n]]} n (after 200 :timeout))
           """) == 2
  end

  # Both shapes really are matched, not just the one the sender happened
  # to use: a beam-lisp vector and the Erlang tuple it lowers to.
  test "a nested pattern matches a tuple and a vector alike" do
    assert eval("gn4", """
           (erlang/send (erlang/self) (tuple :a (tuple :b 3)))
           (receive [:a [:b n]] n (after 200 :timeout))
           """) == 3
  end

  # The alternatives are a Cartesian product, so deep nesting is refused
  # with a count and a remedy rather than emitting hundreds of bodies.
  test "excessive nesting is refused by name, not compiled" do
    err =
      assert_raise BeamLisp.CompileError, fn ->
        eval("gn5", "(receive [[[[[[[n]]]]]]] n (after 10 :t))")
      end

    assert err.message =~ "nests too deeply"
    assert err.message =~ "128"
  end

  # ── defserver ──────────────────────────────────────────────────────

  test "a defserver callback dispatches on a guard" do
    assert eval("gs1", """
           (defserver bank
             (init [x] (ok x))
             (handle-call [:withdraw n] :when (pos? n) [_from state]
               (if (>= state n) (reply :ok (- state n)) (reply :insufficient state)))
             (handle-call [:withdraw n] [_from state] (reply :invalid state))
             (handle-call :balance [_from state] (reply state state)))
           (let [p (server-start-link bank 100)
                 a (server-call p [:withdraw 30])
                 b (server-call p [:withdraw 1000])
                 c (server-call p [:withdraw -5])
                 d (server-call p :balance)]
             (server-stop p)
             (list a b c d))
           """) == [:ok, :insufficient, :invalid, 70]
  end

  # ── the guard dialect, and its edges ───────────────────────────────

  test "the guard vocabulary covers the language's own predicates" do
    assert eval("gv1", """
           (defn kind
             ([x] :when (keyword? x) :keyword)
             ([x] :when (map? x) :map)
             ([x] :when (vector? x) :vector)
             ([x] :when (nil? x) :nil)
             ([x] :when (float? x) :float)
             ([x] :when (int? x) :int)
             ([x] :when (string? x) :string)
             ([x] :when (pid? x) :pid)
             ([_x] :other))
           (to-list (map kind [:k {:a 1} [1] nil 1.5 2 "s" (erlang/self) (list 1)]))
           """) == [:keyword, :map, :vector, nil, :float, :int, :string, :pid, :other]
  end

  # THE contract for the guard dialect: a predicate must mean in a guard
  # exactly what the function of the same name means. A guard form that
  # was subtly narrower would be a trap — code would read as a refactor of
  # an `if` and behave differently.
  #
  # These three were all wrong in the first cut of this wave, in the same
  # direction (the guard was narrower), and each is checked here against
  # the RUNTIME function rather than against a hardcoded expectation.
  test "a guard predicate agrees with the function of the same name" do
    assert eval("gv2", """
           (defrecord GvPoint [a b])
           (defn m? ([x] :when (map? x) true) ([_x] false))
           (defn f? ([x] :when (fn? x) true) ([_x] false))
           (defn p? ([x] :when (pos? x) true) ([_x] false))
           (let [vals [{:a 1} [1 2] (atom 1) (->GvPoint 1 2) (sorted-map :a 1)
                       (fn ([x] x) ([x y] y)) inc 1 -1 :k "s"]]
             ; every value, every predicate, guard form vs function form
             (to-list (map (fn [v] [(= (m? v) (map? v))
                                    (= (f? v) (fn? v))
                                    (= (p? v) (pos? v))])
                           vals)))
           """)
           |> Enum.each(fn row ->
             assert row == %BeamLisp.Vector{items: {true, true, true}},
                    "a guard predicate disagreed with its function: #{inspect(row)}"
           end)
  end

  # `map?` accepts a RECORD and a sorted map, because `RT.map?/1` does: a
  # record is a user-facing map in this language. It excludes the non-map
  # structs (vector, set, lazy seq, refs). Spelled out separately from the
  # agreement test above so the intended answers are visible, not merely
  # consistent.
  test "map? in a guard covers records and sorted maps, not every struct" do
    assert eval("gv2b", """
           (defrecord GvRec [a])
           (defn m? ([x] :when (map? x) true) ([_x] false))
           (list (m? {:a 1}) (m? (->GvRec 1)) (m? (sorted-map :a 1))
                 (m? [1 2]) (m? (atom 1)))
           """) == [true, true, true, false, false]
  end

  # `pos?`/`zero?`/`neg?` are bare comparisons here, exactly as the
  # functions are — and BEAM comparison is a TOTAL order, so `(pos? :k)`
  # is true. Surprising, but it is the language's existing answer, and the
  # guard must not invent a different one. A numeric test is spelled
  # `(and (number? x) (pos? x))`, identically in both positions.
  test "numeric guards use term order, like their functions do" do
    assert eval("gv3", """
           (defn p? ([x] :when (pos? x) :pos) ([_x] :no))
           (defn np? ([x] :when (and (number? x) (pos? x)) :pos) ([_x] :no))
           (list (p? 1) (p? -1) (p? :k) (np? 1) (np? -1) (np? :k))
           """) == [:pos, :no, :pos, :pos, :no, :no]
  end

  # A guard never raises, whatever it is handed — a raising guard would
  # kill the process instead of trying the next clause.
  test "a guard declines rather than raising on an unexpected type" do
    assert eval("gv3b", """
           (defn r? ([x] :when (> (+ x 1) 0) :num) ([_x] :other))
           (list (r? 1) (r? :k) (r? nil) (r? "s"))
           """) == [:num, :other, :other, :other]
  end

  test "and / or / not compose inside a guard" do
    assert eval("gv4", """
           (defn r?
             ([x] :when (and (int? x) (> x 0) (< x 10)) :small)
             ([x] :when (or (string? x) (keyword? x)) :name)
             ([x] :when (not (nil? x)) :other)
             ([_x] :nil))
           (to-list (map r? [5 50 "s" :k 1.5 nil]))
           """) == [:small, :other, :name, :name, :other, nil]
  end

  # Clauses are EMITTED grouped by shape (Elixir requires same-name/arity
  # defs to be adjacent) but must be COMPILED in source order, because
  # compiling a body expands its macros and expansion is observable. A
  # macro that counts would otherwise see interleaved clauses in grouped
  # order — a silent change to what the code means.
  test "clause bodies expand their macros in source order, not grouped order" do
    assert eval("gv5", """
           (def GV-COUNTER (atom 0))
           (defmacro tick [] (swap! GV-COUNTER inc) (deref GV-COUNTER))
           (defn f
             ([_a] (tick))
             ([_a _b] (tick)))
           (list (f 1) (f 1 2))
           """) == [1, 2]
  end

  test "a side-effecting call in a guard is refused, naming the vocabulary" do
    err =
      assert_raise BeamLisp.CompileError, fn ->
        eval("gx1", "(defn f ([x] :when (println x) 1) ([_x] 2))")
      end

    assert err.message =~ "not allowed in a guard"
    assert err.message =~ "`int?`"
  end

  test "a guard may only read variables the head binds" do
    err =
      assert_raise BeamLisp.CompileError, fn ->
        eval("gx2", "(defn f ([x] :when (> y 1) 1) ([_x] 2))")
      end

    assert err.message =~ "not bound by this clause's pattern"
  end

  # A destructured name is bound by a body prelude that has not run when
  # the BEAM evaluates the head, so it is out of scope for the guard.
  # Saying so beats "undefined variable" pointing at generated code.
  test "a guard cannot read a destructured parameter" do
    err =
      assert_raise BeamLisp.CompileError, fn ->
        eval("gx3", "(defn f ([[a b]] :when (int? a) 1) ([_x] 2))")
      end

    assert err.message =~ "not bound by this clause's pattern"
  end

  test "a dangling :when is refused rather than read as a body form" do
    compile_error("gx4", "(defn f [x] :when)")
    compile_error("gx5", "(defn f [x] :when (int? x))")
    compile_error("gx6", "(receive n :when (pos? n))")
  end

  # ── a tuple is positional data ────────────────────────────────
  #
  # The pattern layer always said so — `[p q]` matches an Erlang tuple and
  # a beam-lisp vector alike — but the RUNTIME did not, so `(let [[a b] t])`
  # raised FunctionClauseError from inside RT.nth. Every interop site that
  # received a `{:ok, v}` therefore wrote `(to-list (erlang/tuple_to_list r))`
  # by hand: a conversion the BEAM never needed, present only because two
  # layers of this language disagreed.

  test "a tuple destructures positionally, like the pattern layer always said" do
    assert eval("gt1", "(let [[a b] (tuple :ok 42)] [a b])") ==
             %BeamLisp.Vector{items: {:ok, 42}}
  end

  test "nested tuple destructuring needs no conversion" do
    assert eval("gt2", "(let [[_ok [l r]] (tuple :ok (tuple :x 1))] [l r])") ==
             %BeamLisp.Vector{items: {:x, 1}}
  end

  test "a too-short tuple destructures leniently, exactly as a vector does" do
    assert eval("gt3", "(let [[a b c] (tuple 1 2)] (list a b c))") == [1, 2, nil]
  end

  # The language's own tagged values ARE tuples. Making tuples positional
  # must not hand them a collection surface: a `deftype`/`reify` exists to
  # have no map or seq semantics, and `(count some-fn)` answering 3 would
  # be reading the implementation.
  # `count` RAISES for these (the dispatch table's decided semantics), while
  # `first` answers nil — it is lenient for every non-collection scalar and
  # always was. Both readings agree on the point: the tuple's ELEMENTS are
  # not reachable. A leak would show as `count` answering the field count
  # and `first` answering a field.
  test "internal tagged values stay opaque despite being tuples" do
    assert eval("gt4", """
           (deftype GTLine [a b])
           (list (try (count (->GTLine 1 2)) (catch e :opaque))
                 (first (->GTLine 1 2))
                 (try (count (fn ([x] x) ([x y] y))) (catch e :opaque))
                 (try (nth (->GTLine 1 2) 0) (catch e :opaque)))
           """) == [:opaque, nil, :opaque, :opaque]
  end

  # The exclusion list is the single place that decides data vs machinery.
  # A new tagged representation added without registering it there would
  # silently become readable — this pins the ones that exist today so the
  # omission shows up here rather than as a leaked field.
  test "every internal tuple tag is registered as machinery" do
    tags = BeamLisp.Guards.internal_tuple_tags()

    for tag <- [:"$blfn", :"$remote", :"$macro", :symbol, :bl_deftype, :bl_reify, :bl_vec] do
      assert tag in tags, "#{inspect(tag)} must be registered in internal_tuple_tags/0"
    end

    # And the guard really excludes them, while ordinary data passes.
    refute BeamLisp.RT.count({:bl_deftype, Foo, {1, 2}}) == 3
  rescue
    FunctionClauseError -> :ok
  end
end
