defmodule BeamLisp.Wave9HygieneTest do
  use ExUnit.Case, async: false

  alias BeamLisp.{Env}

  setup do
    BeamLisp.init()
    Env.in_ns("user")
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  describe "prelude macros do not capture user locals" do
    # Before syntax-quote auto-gensym, `and`/`or`/`case` bound fixed
    # temporaries (`and-tmp`/`or-tmp`/`case-val`) that a user local of
    # the same name silently shadowed or was captured by.
    test "and ignores a user local named and-tmp" do
      # pre-fix this returned 1: the macro's own and-tmp (bound to the
      # first arg, 1) shadowed the user's and-tmp (5).
      assert eval("(let [and-tmp 5] (and 1 and-tmp))") == 5
    end

    test "or ignores a user local named or-tmp" do
      # pre-fix this returned false: the macro's or-tmp shadowed the
      # user's or-tmp, so the short-circuit returned the inner binding.
      assert eval("(let [or-tmp 7] (or false or-tmp))") == 7
    end

    test "case temp does not capture a branch value named case-val" do
      # pre-fix this returned 9: the branch value `case-val` referred to
      # the macro's generated binding (bound to the case expression, 9)
      # instead of the user's local (100).
      assert eval("(let [case-val 100] (case 9 9 case-val :other))") == 100
    end

    test "case still matches on the expression value" do
      assert eval("(let [case-val 9] (case case-val 9 :nine :other))") == :nine
      assert eval("(let [case-val 9] (case case-val 8 :eight :other))") == :other
    end
  end

  describe "syntax-quote auto-gensym" do
    test "x# twice in one syntax-quote expands to the same symbol" do
      eval("(defmacro same-temp [] `(quote [x# x#]))")
      assert eval("(let [v (same-temp)] (= (first v) (second v)))") == true

      # and the generated name is the readable x__N__auto shape
      {:symbol, name} = eval("(first (same-temp))")
      assert name =~ ~r/^x__\d+__auto$/
    end

    test "x# in two separate syntax-quotes expands to different symbols" do
      eval("(defmacro temp-a [] `(quote x#))")
      eval("(defmacro temp-b [] `(quote x#))")
      assert eval("(= (temp-a) (temp-b))") == false
    end

    test "unquoted symbols are not renamed" do
      eval("(defmacro keep [s] `(quote ~s))")
      # x# here is a raw macro argument, spliced via ~, so it stays x#
      assert eval("(keep x#)") == {:symbol, "x#"}
    end

    test "nested syntax-quotes get independent gensym maps" do
      eval("(defmacro two-temps [] `(list `(quote x#) `(quote x#)))")
      assert eval("(= (first (two-temps)) (second (two-temps)))") == false
    end

    test "a # in the middle of a symbol is untouched" do
      assert eval("(quote a#b)") == {:symbol, "a#b"}
    end
  end

  describe "the gensym prim" do
    test "(gensym) and (gensym \"p\") produce distinct symbols" do
      assert eval("(= (gensym) (gensym))") == false
      assert eval("(= (gensym \"p\") (gensym \"p\"))") == false
      assert {:symbol, name} = eval("(gensym \"zz\")")
      assert name =~ ~r/^zz__\d+__auto$/
    end

    test "(gensym) yields a usable macro temporary" do
      eval("(defmacro two-g [a b] (let [g (gensym \"t\")] `(let [~g ~a] [~g ~g ~b])))")
      assert eval("(two-g 1 2)") == BeamLisp.Vector.new([1, 1, 2])
    end
  end
end
