defmodule BeamLisp.ReaderWave20PosTest do
  use ExUnit.Case, async: true

  alias BeamLisp.Reader
  alias BeamLisp.FormMeta

  # The position-aware entry returns wrapped forms; pull the position map
  # off a `{:meta, form, m}` wrapper. Forms that never carry a wrapper
  # (scalars, keywords) come back with nil meta — the documented no-op.
  defp pos(form), do: FormMeta.meta(form)
  defp line(form), do: pos(form)[:line]
  defp col(form), do: pos(form)[:col]

  test "a form on line 1 carries line 1, col 1, and the file" do
    [list] = Reader.read_string("(+ 1 2)", "a.bl")

    assert pos(list) == %{line: 1, col: 1, file: "a.bl"}
    assert line(list) == 1
  end

  test "a form on line 5 is attributed to line 5" do
    source = "a\nb\nc\nd\n(+ 1 2)"
    forms = Reader.read_string(source, "f.bl")

    assert [_, _, _, _, list] = forms
    assert line(list) == 5
    assert col(list) == 1
  end

  test "a form after a comment lands on the next line" do
    [list] = Reader.read_string("; leading comment\n(+ 1 2)", "f.bl")
    assert line(list) == 2
    assert col(list) == 1
  end

  test "a form after a blank line lands past it" do
    [list] = Reader.read_string("\n\n(+ 1 2)", "f.bl")
    assert line(list) == 3
  end

  test "two forms on the same line carry their distinct columns" do
    [a, b] = Reader.read_string("(foo)  (bar)", "f.bl")

    assert {line(a), col(a)} == {1, 1}
    assert {line(b), col(b)} == {1, 8}
  end

  test "leading indentation sets the column" do
    [list] = Reader.read_string("    (x)", "f.bl")
    assert col(list) == 5
  end

  test "a nested list carries its own position, independent of its parent" do
    [outer] = Reader.read_string("(outer\n  (inner 1))", "n.bl")

    assert line(outer) == 1
    {:meta, {:list, [{:symbol, "outer"}, inner]}, _} = outer
    # The inner list opens on line 2 — the parent's line must not leak down.
    assert line(inner) == 2
    assert col(inner) == 3
  end

  test "only lists carry position; symbols and scalars stay bare" do
    # The narrowed design. A symbol is as often a *shape token* as a value
    # — a parameter, a binding name, a `def` name — and the compiler matches
    # those structurally in ~50 places. Wrapping them would demand
    # meta-tolerance at every one for per-symbol columns nothing reports.
    # A list is where evaluation happens, so a list is what an error names.
    [sym] = Reader.read_string("foo", "f.bl")
    assert sym == {:symbol, "foo"}
    assert pos(sym) == nil

    [kw] = Reader.read_string(":ok", "f.bl")
    assert kw == {:keyword, "ok"}

    [num] = Reader.read_string("42", "f.bl")
    assert num == 42

    [list] = Reader.read_string("(foo 42)", "f.bl")
    assert %{line: 1, col: 1, file: "f.bl"} = pos(list)
  end

  test "file is threaded into every list, nested and sibling alike" do
    [a, b] = Reader.read_string("(one)\n(two (three))", "src/app.bl")

    assert pos(a)[:file] == "src/app.bl"
    assert pos(b)[:file] == "src/app.bl"
    assert line(b) == 2

    {:meta, {:list, [{:symbol, "two"}, nested]}, _} = b
    assert pos(nested)[:file] == "src/app.bl"
  end

  test "read_string/1 defaults the file to nil" do
    [list] = Reader.read_string("(+ 1 2)")
    assert pos(list) == %{line: 1, col: 1, file: nil}
  end

  test "read_all/read_one still return the bare shapes" do
    assert Reader.read_one("(+ 1 2)") == {:list, [{:symbol, "+"}, 1, 2]}
    assert Reader.read_one("foo") == {:symbol, "foo"}

    assert Reader.read_all("(def x 1) (+ x 2)") == [
             {:list, [{:symbol, "def"}, {:symbol, "x"}, 1]},
             {:list, [{:symbol, "+"}, {:symbol, "x"}, 2]}
           ]
  end

  test "vectors, maps and sets stay bare — they are shape tokens too" do
    # A param vector, a `let` binding vector and a destructuring pattern are
    # all `{:vector, _}`; positions on them would break the same ~14 sites.
    [vec] = Reader.read_string("[1 2]", "f.bl")
    assert pos(vec) == nil
    [map] = Reader.read_string("{:a 1}", "f.bl")
    assert pos(map) == nil
    [set] = Reader.read_string("#" <> "{1}", "f.bl")
    assert pos(set) == nil
  end

  test "fn literal, quote and deref sugar attach the prefix position" do
    [fn_form] = Reader.read_string("#(+ % 1)", "f.bl")
    assert {line(fn_form), col(fn_form)} == {1, 1}

    [quoted] = Reader.read_string("'foo", "f.bl")
    assert {line(quoted), col(quoted)} == {1, 1}

    [deref] = Reader.read_string("@x", "f.bl")
    assert {line(deref), col(deref)} == {1, 1}
  end

  test "auto-gensym and char literals are unaffected by position tracking" do
    assert Reader.read_one("x#") == {:symbol, "x#"}
    assert Reader.read_one("\\a") == ?a
    assert Reader.read_one("\\newline") == ?\n
  end
end
