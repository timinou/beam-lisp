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
end
