defmodule BeamLisp.ReaderTest do
  use ExUnit.Case, async: true

  alias BeamLisp.Reader
  alias BeamLisp.Reader.SyntaxError

  test "literals" do
    assert Reader.read_one("42") == 42
    assert Reader.read_one("-7") == -7
    assert Reader.read_one("2.5") == 2.5
    assert Reader.read_one("1e3") == 1000.0
    assert Reader.read_one(~s("hello")) == "hello"
    assert Reader.read_one(~s("a\\nb")) == "a\nb"
    assert Reader.read_one("nil") == nil
    assert Reader.read_one("true") == true
    assert Reader.read_one("false") == false
  end

  test "symbols and keywords" do
    assert Reader.read_one("foo") == {:symbol, "foo"}
    assert Reader.read_one("IO/puts") == {:symbol, "IO/puts"}
    assert Reader.read_one("+") == {:symbol, "+"}
    assert Reader.read_one("not=") == {:symbol, "not="}
    assert Reader.read_one(":ok") == {:keyword, "ok"}
  end

  test "quoted keyword literals (BUG-004)" do
    # A `:"..."` name may hold chars no bare symbol can. Before the fix the
    # `:` terminated at the `"` and the input read as TWO forms — the empty
    # keyword then a string.
    assert Reader.read_one(~s(:"a b")) == {:keyword, "a b"}
    assert Reader.read_one(~s(:"$end_of_table")) == {:keyword, "$end_of_table"}
    assert Reader.read_one(~s(:"Elixir.ReqLLM.Response")) == {:keyword, "Elixir.ReqLLM.Response"}

    # The precise regression: ONE form out, not two.
    assert length(Reader.read_string(~s(:"a b"))) == 1

    # Escapes behave as in a normal string (shared string/3).
    assert Reader.read_one(~s(:"tab\there")) == {:keyword, "tab\there"}

    # A quoted keyword is a map key like any other.
    assert Reader.read_one(~s({:"weird key" 1})) == {:map, [{{:keyword, "weird key"}, 1}]}
  end

  test "collections" do
    assert Reader.read_one("(+ 1 2)") == {:list, [{:symbol, "+"}, 1, 2]}
    assert Reader.read_one("[1 2 3]") == {:vector, [1, 2, 3]}
    assert Reader.read_one("[]") == {:vector, []}
    assert Reader.read_one("()") == {:list, []}
    assert Reader.read_one("{:a 1 :b 2}") == {:map, [{{:keyword, "a"}, 1}, {{:keyword, "b"}, 2}]}
  end

  test "nesting" do
    assert Reader.read_one("(f [1 (g 2)] {:k 3})") ==
             {:list,
              [
                {:symbol, "f"},
                {:vector, [1, {:list, [{:symbol, "g"}, 2]}]},
                {:map, [{{:keyword, "k"}, 3}]}
              ]}
  end

  test "quote sugar" do
    assert Reader.read_one("'foo") == {:list, [{:symbol, "quote"}, {:symbol, "foo"}]}
    assert Reader.read_one("'(a b)") == {:list, [{:symbol, "quote"}, {:list, [{:symbol, "a"}, {:symbol, "b"}]}]}
  end

  test "comments and commas are whitespace" do
    assert Reader.read_all("; nothing here\n(+ 1, 2) ; trailing") ==
             [{:list, [{:symbol, "+"}, 1, 2]}]
  end

  test "multiple forms" do
    assert Reader.read_all("(def x 1) (+ x 2)") ==
             [
               {:list, [{:symbol, "def"}, {:symbol, "x"}, 1]},
               {:list, [{:symbol, "+"}, {:symbol, "x"}, 2]}
             ]
  end

  test "syntax errors" do
    assert_raise SyntaxError, fn -> Reader.read_one("(+ 1") end
    assert_raise SyntaxError, fn -> Reader.read_one(")") end
    assert_raise SyntaxError, fn -> Reader.read_one("{:a}") end
    assert_raise SyntaxError, fn -> Reader.read_one(~s("open)) end
  end

  describe "unicode escapes" do
    # `\uXXXX` used to drop its backslash and keep the letter, so
    # `"\u2713"` read as the four characters `u2713` — silently, with no
    # error, and only visible wherever the string was eventually
    # displayed. That is how 32 mangled escapes once reached 8 files in
    # this repository (BUG-020).
    test "four-digit escapes decode to one character" do
      assert Reader.read_one(~S|"\u2713"|) == "✓"
      assert Reader.read_one(~S|"\u00e9"|) == "é"
      assert String.length(Reader.read_one(~S|"\u2713"|)) == 1
    end

    test "braced escapes reach above the BMP" do
      # Elixir's spelling, and the only way to write a codepoint past
      # 0xFFFF without surrogate pairs.
      assert Reader.read_one(~S|"\u{1D11E}"|) == "𝄞"
      assert Reader.read_one(~S|"\u{41}"|) == "A"
    end

    test "escapes compose with surrounding text" do
      assert Reader.read_one(~S|"a\u2713b"|) == "a✓b"
      assert Reader.read_one(~S|"\u2713\u2713"|) == "✓✓"
    end

    test "the other escapes still work" do
      assert Reader.read_one(~S|"a\nb"|) == "a\nb"
      assert Reader.read_one(~S|"a\tb"|) == "a\tb"
      assert String.length(Reader.read_one(~S|"a\\b"|)) == 3
    end

    test "a malformed escape is an ERROR, not a mangled string" do
      # The whole point: accepting the syntax and corrupting it is worse
      # than rejecting it, because the syntax looks supported.
      # Raised, not returned: the reader's contract is that a syntax
      # error stops the read rather than producing a value the caller
      # has to inspect.
      assert_raise Reader.SyntaxError, fn -> Reader.read_all(~S|"\u27"|) end
      assert_raise Reader.SyntaxError, fn -> Reader.read_all(~S|"\uZZZZ"|) end
      assert_raise Reader.SyntaxError, fn -> Reader.read_all(~S|"\u{}"|) end
    end

    test "a surrogate half is rejected" do
      # Not a codepoint. Encoding one yields invalid UTF-8 that fails
      # much later, at whatever tries to print it.
      assert_raise Reader.SyntaxError, fn -> Reader.read_all(~S|"\uD800"|) end
    end
  end
end
