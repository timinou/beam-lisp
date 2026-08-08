defmodule BeamLisp.Wave27DestructureTest do
  # Quoted-symbol keys in map destructuring: `{binding 'sym}` / `{binding (quote sym)}`.
  #
  # This is the single biggest Specter load wall — Specter's `nav` macro
  # destructures its implementations against a LITERAL QUOTED SYMBOL as the
  # map key:
  #
  #     {[[_ s-sym s-next] & s-body] 'select* ...}
  #
  # The reader turns `'sym` into `(quote sym)`, so both must work. The runtime
  # key is the tagged `{:symbol, name}` tuple a quoted symbol evaluates to
  # (the reader's `datum/1` preserves that shape); the lookup is by symbol
  # value, not by a keyword. All existing key kinds — keyword, string,
  # `:keys`/`:strs`/`:syms`, `:as`, `:or`, nested patterns — are unchanged.
  #
  # Lenient destructuring is a project invariant: a missing key binds nil.
  #
  # Quoted symbols that happen to spell directive names (`'keys`/`'as`/`'or`)
  # are KEYS, not directives — structurally a quote list can never match the
  # bare-keyword directive clauses, so the ambiguity resolves by construction.
  use ExUnit.Case, async: false

  @moduletag :wave27

  defp eval(ns, source) do
    BeamLisp.init()
    BeamLisp.Compiler.eval_string(source, BeamLisp.Compiler.new_env(ns))
  end

  test "reader shorthand {x 'foo} looks up by the symbol value" do
    assert eval("w27short", "(let [{x 'foo} {'foo 42}] x)") == 42
  end

  test "expanded (quote foo) form works the same as the shorthand" do
    assert eval("w27quote", "(let [{x (quote foo)} {'foo 7}] x)") == 7
  end

  test "nested vector pattern with & rest against a quoted-symbol key" do
    # The Specter nav shape: bind a nested vector (and its rest) from the
    # value stored under a quoted-symbol key. Both halves must cooperate —
    # a test covering only `{x 'foo}` proves nothing about this.
    assert eval("w27nested", "(let [{[a b & rest] 'sel} {'sel '(10 20 30 40)}] (list a b rest))") ==
             [10, 20, [30, 40]]
  end

  test "nested pattern works on the real Specter select* shape" do
    # determine-params-impls maps 'select* to the impl body whose first
    # element is the params vector: `([this vals structure next-fn] ...)`.
    source = """
    (defn determine-params-impls [impls]
      {'select* '([this vals structure next-fn] (next-fn vals structure))
       'transform* '([this vals structure next-fn] (next-fn vals structure))})
    (defmacro nav [params & impls]
     (let [{[[_ s-structure-sym s-next-fn-sym] & s-body] 'select*
            [[_ t-structure-sym t-next-fn-sym] & t-body] 'transform*}
           (determine-params-impls impls)]
       ;; splice the bound symbols back out as data, the way Specter splices
       ;; them into the emitted code — quoting keeps them symbols, not vars
       `(list '~s-structure-sym '~s-next-fn-sym '~t-structure-sym '~t-next-fn-sym)))
    (nav foo
      (select* [this vals structure next-fn] (next-fn vals structure))
      (transform* [this vals structure next-fn] (next-fn vals structure)))
    """
    assert eval("w27specter", source) ==
             [{:symbol, "vals"}, {:symbol, "structure"}, {:symbol, "vals"}, {:symbol, "structure"}]
  end

  test ":or default applies when the quoted-symbol key is absent" do
    assert eval("w27or", "(let [{x 'missing :or {x 99}} {}] x)") == 99
    # a present key with a nil value stays nil — Map.get/3 semantics
    assert eval("w27orpresent", "(let [{x 'k :or {x 99}} {'k nil}] x)") == nil
  end

  test ":as binds the whole map alongside quoted-symbol keys" do
    assert eval("w27as", "(let [{x 'foo :as whole} {'foo 5 'bar 6}] (list x (get whole 'bar)))") ==
             [5, 6]
  end

  test "'keys/'as/'or are keys, not destructuring directives" do
    assert eval("w27kw", "(let [{a 'keys b 'as c 'or} {'keys 1 'as 2 'or 3}] (list a b c))") ==
             [1, 2, 3]
  end

  test "the real :keys/:as/:or directives still work alongside quoted keys" do
    source = """
    (let [{a 'sel :keys [k] :or {k 9} :as whole}
          {'sel 1 :k 2}]
      (list a k (get whole 'sel)))
    """
    assert eval("w27mix", source) == [1, 2, 1]
  end

  test "missing quoted-symbol key binds nil leniently (no raise)" do
    assert eval("w27nil", "(let [{x 'foo} {}] (nil? x))") == true
  end

  test "keyword and string keys still destructure unchanged" do
    assert eval("w27keep", "(let [{k :kw s \"str\"} {:kw 1 \"str\" 2}] (list k s))") == [1, 2]
  end
end
