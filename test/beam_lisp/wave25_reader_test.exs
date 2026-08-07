defmodule BeamLisp.Wave25ReaderTest do
  # Wave 25: the two reader gaps the jank and Specter measurements landed on —
  # `^` reader metadata and `#?` reader conditionals.
  #
  # `^` is the gate for jank's `^{:arglists}`/`^{:inline}`/`^:private` dialect
  # at the head of core.jank (slices 65/77/78 and everything behind them).
  # `#?` is the gate for reading *any* `.cljc` file (Specter is 139
  # conditionals across its modules; slices 08/28/29).
  #
  # The two halves assert at different depths:
  #   * reader-level tests check the shape of what `^`/`#?` read into
  #     (the `{:meta, form, m}` wrapper and the selected/spliced forms);
  #   * compiler-level tests check the payoff — `^{:doc ...}` on a `def`/
  #     `defn` landing in the var's metadata, readable via `Env.meta` and
  #     `doc`.
  #
  # Regression contract: wave-20 source positions must keep riding on lists
  # (the tests at the bottom), and the wave20_* test files stay green.
  # NOT async: these drive the compiler, which rebuilds the shared
  # BeamLisp.Ns.* modules and writes the global var table. Two of them
  # running concurrently race Module.create on the same module name.
  use ExUnit.Case, async: false

  alias BeamLisp.{Compiler, Env, FormMeta, Reader}

  defp read(src), do: Reader.read_string(src, "w25.bl")
  defp read1(src), do: Reader.read_one(src)
  defp env(ns), do: Compiler.new_env(ns)

  # --- `^` reader metadata: the four shorthands ---

  test "^:kw attaches {:kw true} to the following form" do
    [form] = read("^:private some-name")
    assert form == {:meta, {:symbol, "some-name"}, %{private: true}}
  end

  test "^{map} attaches the map itself" do
    [form] = read("^{:doc \"hi\"} x")
    assert {:meta, {:symbol, "x"}, meta} = form
    assert meta[:doc] == "hi"
  end

  test "^Sym attaches {:tag Sym}" do
    [form] = read("^String x")
    assert form == {:meta, {:symbol, "x"}, %{tag: {:symbol, "String"}}}
  end

  test "^\"str\" attaches {:tag \"str\"}" do
    [form] = read("^\"a type\" x")
    assert form == {:meta, {:symbol, "x"}, %{tag: "a type"}}
  end

  test "stacked ^ metadata merges (^:private ^:static x)" do
    [form] = read("^:private ^:static x")
    assert form == {:meta, {:symbol, "x"}, %{private: true, static: true}}
  end

  test "^ metadata on a list merges with its source position" do
    [form] = read("^{:doc \"d\"} (foo 1)")
    assert {:meta, {:list, [{:symbol, "foo"}, 1]}, meta} = form
    # The user metadata and the wave-20 position share one wrapper but stay
    # disjoint by key: the position is still there for error attribution.
    # The column is where the LIST opens (after the metadata prefix), not 1.
    assert meta[:doc] == "d"
    assert meta[:line] == 1
    assert meta[:col] == 12
    assert meta[:file] == "w25.bl"
  end

  test "^ metadata survives on the def/defn name symbol" do
    [form] = read("(def ^{:doc \"x\"} foo 1)")
    # The whole list carries its position wrapper; the def name symbol
    # carries the `^` metadata, unwrapped only by name_of/1.
    assert {:meta, {:list, [{:symbol, "def"}, {:meta, {:symbol, "foo"}, %{doc: "x"}}, 1]}, _} =
             form
  end

  test "^ with no following form is a reader error" do
    assert_raise BeamLisp.Reader.SyntaxError, fn -> read1("^:private") end
  end

  test "^{...} map keys must be keywords" do
    assert_raise BeamLisp.Reader.SyntaxError, fn -> read1("^{foo 1} x") end
  end

  # --- `^` landing in var metadata ---

  test "^{:doc ...} on a def lands in the var's metadata, readable via Env.meta" do
    BeamLisp.init()
    Compiler.eval_string("(def ^{:doc \"adds one\"} add1 (fn [x] (+ x 1)))", env("w25"))
    assert {:ok, meta} = Env.meta("w25", "add1")
    assert meta[:doc] == "adds one"
  end

  test "^:private on a def lands in the var's metadata" do
    BeamLisp.init()
    Compiler.eval_string("(def ^:private secret 42)", env("w25p"))
    assert {:ok, meta} = Env.meta("w25p", "secret")
    assert meta[:private] == true
  end

  test "stacked ^{:doc} ^:private on a defn land in the var's metadata" do
    BeamLisp.init()
    Compiler.eval_string("(defn ^{:doc \"mult\"} ^:private mul [a b] (* a b))", env("w25m"))
    assert {:ok, meta} = Env.meta("w25m", "mul")
    assert meta[:doc] == "mult"
    assert meta[:private] == true
  end

  test "defn's docstring and ^{...} metadata both land in the var's metadata" do
    BeamLisp.init()
    Compiler.eval_string("(defn ^{:arglists '([x])} twice \"doubles\" [x] (* 2 x))", env("w25d"))
    assert {:ok, meta} = Env.meta("w25d", "twice")
    assert meta[:doc] == "doubles"
    # `'([x])` compiles to a list whose single element is the vector [x].
    assert %BeamLisp.Vector{items: {{:symbol, "x"}}} = List.first(meta[:arglists])
  end

  test "defn accepts a Clojure attr-map literal after the docstring" do
    BeamLisp.init()
    Compiler.eval_string("(defn bitnot \"complement\" {:inline (fn* [o] o)} [x] (- x))", env("w25a"))
    assert {:ok, meta} = Env.meta("w25a", "bitnot")
    assert meta[:doc] == "complement"
    assert is_function(meta[:inline]) or meta[:inline] != nil
  end

  test "doc/1 and meta see the ^ doc" do
    BeamLisp.init()
    Compiler.eval_string("(def ^{:doc \"the doc\"} ddoc 7)", env("w25doc"))
    assert {:ok, meta} = Env.meta("w25doc", "ddoc")
    assert meta[:doc] == "the doc"
  end

  # --- `#?` reader conditional: selection ---

  test "#? selects the :clj branch" do
    assert read1("#?(:clj 1 :cljs 2)") == 1
  end

  test "#? skips a non-matching branch and picks the matching one" do
    assert read1("#?(:cljs 1 :clj 2)") == 2
  end

  test "#? falls back to :default when no platform branch matches" do
    assert read1("#?(:cljs 1 :clj 2 :default 3)") == 2
    assert read1("#?(:cljs 1 :default 3)") == 3
  end

  test "#? with no matching feature and no :default is a reader error" do
    assert_raise BeamLisp.Reader.SyntaxError, fn -> read1("#?(:cljs 1)") end
  end

  test "#? feature must be a keyword" do
    assert_raise BeamLisp.Reader.SyntaxError, fn -> read1("#?(foo 1 :clj 2)") end
  end

  # --- `#?@` reader conditional: splicing ---

  test "#?@ splices a vector branch into a vector" do
    assert read1("[0 #?@(:clj [1 2] :cljs [9]) 3]") == {:vector, [0, 1, 2, 3]}
  end

  test "#?@ splices into a list" do
    assert read1("(a #?@(:cljs [x] :clj [b c]) d)") ==
             {:list, [{:symbol, "a"}, {:symbol, "b"}, {:symbol, "c"}, {:symbol, "d"}]}
  end

  test "#?@ uses :default when no platform branch matches" do
    assert read1("[#?@(:cljs [1] :default [2 3])]") == {:vector, [2, 3]}
  end

  test "#?@ requires the selected branch to be a collection" do
    assert_raise BeamLisp.Reader.SyntaxError, fn -> read1("[#?@(:clj 1)]") end
  end

  test "#?@ at the top level is refused" do
    assert_raise BeamLisp.Reader.SyntaxError, fn -> read1("#?@(:clj [1 2])") end
  end

  test "#? misread as a bare symbol is gone (a real read, not a symbol)" do
    assert read1("#?(:clj 5 :cljs 6)") == 5
  end

  # --- regression: wave-20 positions still ride on lists ---

  test "a def with ^ metadata still carries its source line" do
    [list] = read("(def ^{:doc \"x\"} foo 1)")
    assert {:meta, {:list, _}, m} = list
    assert m[:line] == 1
    assert m[:col] == 1
    assert m[:file] == "w25.bl"
  end

  test "positions on nested lists under ^ are intact" do
    [list] = read("(outer\n  ^{:doc \"d\"} (inner 1))")
    assert {:meta, {:list, [{:symbol, "outer"}, inner]}, _} = list
    assert FormMeta.meta(inner)[:line] == 2
  end

  test "read_all/read_one still deep-unwrap ^ metadata and positions" do
    assert Reader.read_one("^:private foo") == {:symbol, "foo"}
    assert Reader.read_one("(def ^{:doc \"x\"} foo 1)") ==
             {:list, [{:symbol, "def"}, {:symbol, "foo"}, 1]}
  end
end
