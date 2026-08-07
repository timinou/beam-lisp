defmodule BeamLisp.Wave19StrTest do
  # `str` on a collection.
  #
  # Found while prototyping lenses in beam-lisp: `(str "x " {:a 1})`
  # raised `Protocol.UndefinedError: String.Chars not implemented for
  # Map`, because `to_str/1`'s fallback was `Kernel.to_string/1` and no
  # BEAM collection implements String.Chars.
  #
  # Clojure's `str` is defined in terms of the printed representation,
  # so a collection stringifies to its literal syntax. beam-lisp already
  # had that printer — `print_str/1`, behind `pr-str` — so the fix was
  # to delegate rather than to write a second stringifier.
  #
  # The distinction `str` must still preserve: a *bare string* prints
  # raw ("a", not "\"a\""), while a string nested inside a collection
  # keeps its quotes, because that is what makes the output re-readable.
  use ExUnit.Case, async: false

  @moduletag :wave19

  defp eval(source) do
    BeamLisp.init()
    BeamLisp.Compiler.eval_string(source, BeamLisp.Compiler.new_env("wave19str"))
  end

  test "collections stringify to their literal syntax" do
    assert eval(~S/(str {:a 1})/) == "{:a 1}"
    assert eval(~S/(str [1 2 3])/) == "[1 2 3]"
    assert eval(~S/(str (list 1 2 3))/) == "(1 2 3)"
  end

  test "nested collections survive interpolation into a larger string" do
    assert eval(~S/(str "user: " {:name "ada"})/) == ~S/user: {:name "ada"}/
  end

  test "a bare string still prints raw, unquoted" do
    # (str "a" "b") is concatenation, not a printed pair of quoted strings.
    assert eval(~S/(str "a" "b")/) == "ab"
  end

  test "scalars keep their existing behaviour" do
    assert eval(~S/(str "a" 1 :kw nil "b")/) == "a1kwb"
    assert eval(~S/(str 'foo)/) == "foo"
    assert eval(~S/(str)/) == ""
  end

  test "a lazy seq stringifies without forcing the whole world" do
    assert eval(~S/(str (map inc [1 2]))/) == "(2 3)"
  end

  test "a set stringifies to set syntax" do
    # Built by concatenation: `#" <> "{` in an Elixir literal would be
    # string interpolation, not the set-literal syntax we are asserting.
    assert eval(~S/(str (set [1]))/) == "#" <> "{1}"
  end
end
