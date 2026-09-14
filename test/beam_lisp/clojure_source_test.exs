defmodule BeamLisp.ClojureSourceTest do
  @moduledoc """
  Clojure source on the load path.

  A Clojure library on disk is not a beam-lisp library with a different
  extension: it arrives with conventions the loader never had to honour before.
  Two of them decide whether the file is found at all, and one decides whether
  it survives its first form.

  1. **The extension.** `.clj` and `.cljc` are source. `.cljs` is not — its
     contents are ClojureScript, and this platform presents as `:clj`.
  2. **The name.** A namespace's dashes are underscores in the file name
     (`kontor.tax.corporate-income-tax` lives at `corporate_income_tax.clj`),
     which is every Clojure library's layout and none of beam-lisp's.
  3. **The docstring.** `(ns app "what it is" (:require …))` is ordinary
     Clojure; the string is not a clause, and walking it as one used to end
     inside the host with a raw argument error.

  Resolution ORDER is asserted, not merely resolution: a project's own `.bl`
  must still shadow a Clojure file that claims the same namespace, and a `.clj`
  must win over a `.cljc` exactly as it does on the JVM.
  """
  use ExUnit.Case, async: false

  alias BeamLisp.{Env, Loader}

  setup do
    BeamLisp.init()
    Env.clear_search_paths()

    on_exit(fn -> Env.clear_search_paths() end)

    :ok
  end

  defp tmp_dir!(label) do
    Path.join(System.tmp_dir!(), "blclj_#{label}_#{System.unique_integer([:positive])}")
  end

  # A fresh namespace per test: namespaces load ONCE per VM, so a shared name
  # would have the second test assert against the first test's image.
  defp uniq_ns(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp munge(ns), do: ns |> String.replace(".", "/") |> String.replace("-", "_")

  defp write_source!(dir, rel, body) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp load_and_eval(dir, ns, expr) do
    Env.add_search_path(dir)
    assert :ok = Loader.ensure_loaded(ns)
    BeamLisp.Compiler.eval_string(expr)
  end

  test "a .clj file serves a require" do
    dir = tmp_dir!("clj")
    ns = uniq_ns("cljlib")
    write_source!(dir, munge(ns) <> ".clj", "(ns #{ns})\n(defn answer [] 41)\n")

    assert 41 == load_and_eval(dir, ns, "(#{ns}/answer)")

    File.rm_rf!(dir)
  end

  test "a .cljc file serves a require, reader conditionals and all" do
    dir = tmp_dir!("cljc")
    ns = uniq_ns("cljclib")

    write_source!(
      dir,
      munge(ns) <> ".cljc",
      """
      (ns #{ns})
      (defn where [] #?(:clj :jvm-lane :cljs :js-lane))
      (defn docstring? [] (string? "yes"))
      """
    )

    # The platform presents as `:clj`, so the `:clj` branch is the one loaded.
    assert :"jvm-lane" == load_and_eval(dir, ns, "(#{ns}/where)")

    File.rm_rf!(dir)
  end

  test "a dashed namespace resolves to its underscore file name" do
    # The convention that makes every Clojure library on disk reachable.
    dir = tmp_dir!("munged")
    ns = uniq_ns("clj-lib-dashed")
    rel = munge(ns) <> ".clj"
    assert rel =~ "_"

    write_source!(dir, rel, "(ns #{ns})\n(defn source [] :underscore-file)\n")

    assert :"underscore-file" == load_and_eval(dir, ns, "(#{ns}/source)")

    File.rm_rf!(dir)
  end

  test "the literal dashed spelling still resolves" do
    # A beam-lisp tree that named a file with the dash keeps working: the
    # literal spelling is tried before the munged one.
    dir = tmp_dir!("literal")
    ns = uniq_ns("clj-lib-literal")
    write_source!(dir, String.replace(ns, ".", "/") <> ".bl", "(ns #{ns})\n(defn source [] :literal-file)\n")

    assert :"literal-file" == load_and_eval(dir, ns, "(#{ns}/source)")

    File.rm_rf!(dir)
  end

  test ".clj wins over .cljc, as it does on the JVM" do
    dir = tmp_dir!("precedence")
    ns = uniq_ns("cljlib_both")
    write_source!(dir, munge(ns) <> ".clj", "(ns #{ns})\n(defn which [] :from-clj)\n")
    write_source!(dir, munge(ns) <> ".cljc", "(ns #{ns})\n(defn which [] :from-cljc)\n")

    assert :"from-clj" == load_and_eval(dir, ns, "(#{ns}/which)")

    File.rm_rf!(dir)
  end

  test "a project's .bl shadows a Clojure file claiming the same ns" do
    dir = tmp_dir!("shadow")
    ns = uniq_ns("cljlib_shadow")
    write_source!(dir, munge(ns) <> ".bl", "(ns #{ns})\n(defn which [] :bl)\n")
    write_source!(dir, munge(ns) <> ".clj", "(ns #{ns})\n(defn which [] :clj)\n")

    assert :bl == load_and_eval(dir, ns, "(#{ns}/which)")

    File.rm_rf!(dir)
  end

  test "a namespace docstring is accepted, not walked as a clause" do
    # The crash this closes was a raw host argument error, so the assertion is
    # that the namespace LOADS with its docstring in place.
    dir = tmp_dir!("nsdoc")
    ns = uniq_ns("cljlib_doc")
    write_source!(dir, munge(ns) <> ".clj", """
    (ns #{ns}
      "A docstring."
      (:require [clojure.string :as s]))

    (defn shout [] (s/upper-case "hi"))
    """)

    assert "HI" == load_and_eval(dir, ns, "(#{ns}/shout)")

    File.rm_rf!(dir)
  end

  test "a branch-less reader conditional reads as nothing, as in Clojure" do
    # `[1 #?(:cljs :x) 2]` is `[1 2]` on the JVM (verified against the Clojure
    # reader). `.cljc` libraries depend on it: a cljs-only require and a
    # cljs-only implementation are skipped, not refused.
    assert [1, 2] == BeamLisp.Compiler.eval_string("[1 #?(:cljs :skipped) 2]") |> Enum.to_list()
    assert [] == BeamLisp.Compiler.eval_string("[#?@(:cljs [1 2 3])]") |> Enum.to_list()
    assert [1] == BeamLisp.Compiler.eval_string("[1 #?( :cljs :skipped)]") |> Enum.to_list()

    # A dangling feature with NO expr: skipped when it is not ours (there is no
    # branch to take), an error when it IS ours (the form is malformed). Both
    # verified against the JVM reader: `[1 #?(:cljs) 2]` → `[1 2]`, while
    # `[1 #?(:clj) 2]` raises, and a dangling feature AFTER a match is never
    # reached at all.
    assert [1, 2] == BeamLisp.Compiler.eval_string("[1 #?(:cljs) 2]") |> Enum.to_list()
    assert [1] == BeamLisp.Compiler.eval_string("[#?(:clj 1 :cljs)]") |> Enum.to_list()

    assert_raise BeamLisp.Reader.SyntaxError, ~r/odd number of forms/, fn ->
      BeamLisp.Compiler.eval_string("[1 #?(:clj) 2]")
    end
  end

  test "a .cljc namespace with a cljs-only require and cljs-only impl loads" do
    dir = tmp_dir!("cljc-skip")
    ns = uniq_ns("cljlib_cljs_skip")

    write_source!(dir, munge(ns) <> ".cljc", """
    (ns #{ns}
      "Clojure on one platform, something else on the other."
      (:require #?(:clj [clojure.string :as str])
                #?(:cljs [some.client-only.lib :as bd])))

    #?(:cljs (defn amount [] :a-bigint))
    #?(:clj  (defn amount [] :a-decimal))

    (defn shout [] (str/upper-case "hi"))
    """)

    assert "HI" == load_and_eval(dir, ns, "(#{ns}/shout)")
    assert :"a-decimal" == BeamLisp.Compiler.eval_string("(#{ns}/amount)")

    File.rm_rf!(dir)
  end
  test "a real Clojure library namespace loads from a nested tree" do
    # The shape a ported library arrives in: a docstring, a dashed namespace,
    # a nested directory, requiring a sibling — all at once.
    dir = tmp_dir!("library")
    pkg = uniq_ns("acme.tax")
    inner = pkg <> ".rate-schedule"

    write_source!(dir, munge(inner) <> ".clj", """
    (ns #{inner}
      "The rate half of a tax: base in, liability out."
      (:require [clojure.string :as str]))

    (defn label [] (str/join "-" ["rate" "schedule"]))
    (defn flat [rate base] (* rate base))
    """)

    write_source!(dir, munge(pkg) <> ".clj", """
    (ns #{pkg}
      "An outer namespace requiring the dashed sibling."
      (:require [#{inner} :as rs]))

    (defn name-of-lib [] (rs/label))
    (defn tax [base] (rs/flat 3 base))
    """)

    assert "rate-schedule" == load_and_eval(dir, pkg, "(#{pkg}/name-of-lib)")
    assert 21 == BeamLisp.Compiler.eval_string("(#{pkg}/tax 7)")

    File.rm_rf!(dir)
  end

  test "an :import clause records the class by short name and loads nothing" do
    BeamLisp.Compiler.eval_string("""
    (ns import.probe
      (:import [java.math BigDecimal RoundingMode]
               (java.util Date)
               java.security.MessageDigest))
    """)

    assert "java.math.BigDecimal" == BeamLisp.Env.import_target("import.probe", "BigDecimal")
    assert "java.math.RoundingMode" == BeamLisp.Env.import_target("import.probe", "RoundingMode")
    assert "java.util.Date" == BeamLisp.Env.import_target("import.probe", "Date")
    assert "java.security.MessageDigest" == BeamLisp.Env.import_target("import.probe", "MessageDigest")
    assert nil == BeamLisp.Env.import_target("import.probe", "UUID")
  end

  test "an :import spec must be package-qualified with class names" do
    assert_raise BeamLisp.CompileError, ~r/invalid :import spec/, fn ->
      BeamLisp.Compiler.eval_string("(ns import.bad (:import [java.math]))")
    end

    assert_raise BeamLisp.CompileError, ~r/invalid :import spec/, fn ->
      BeamLisp.Compiler.eval_string("(ns import.bad2 (:import Date))")
    end
  end

  test ":refer-clojure :exclude is recorded and the same-ns def shadows core" do
    r =
      BeamLisp.Compiler.eval_string("""
      (do
        (ns refer.probe (:refer-clojure :exclude [zero? name]))
        (defn zero? [_] :shadowed)
        (zero? 0))
      """)

    assert :shadowed == r
    assert ["zero?", "name"] == BeamLisp.Env.core_excludes("refer.probe")
    assert [] == BeamLisp.Env.core_excludes("import.probe")

    assert_raise BeamLisp.CompileError, ~r/supports only :exclude/, fn ->
      BeamLisp.Compiler.eval_string("(ns refer.bad (:refer-clojure :only [inc]))")
    end
  end

  test "an unknown ns clause is refused by name" do
    assert_raise BeamLisp.CompileError, ~r/got :use/, fn ->
      BeamLisp.Compiler.eval_string("(ns clause.bad (:use [x]))")
    end
  end

  # The reader's answers for reader conditionals, CAPTURED FROM THE JVM READER
  # AND EVALUATOR (`clojure -M -e` over these exact sources) — an oracle, not a
  # re-statement of this implementation. Which cases pin which rule:
  #
  #   [#?(:cljs)]            -> []      a dangling NON-matching feature is no
  #                                     branch to take, not a malformed form
  #   [#?(:clj)]             -> error   a dangling MATCHING feature is malformed
  #   [#?(:clj 1 :cljs)]     -> [1]     …and a dangling feature after a match is
  #                                     never reached
  #   [1 #? (:cljs 2) 3]     -> [1 3]   `#? (` may carry whitespace
  #   [1 #?@ (:clj [2 3]) 4] -> [1 2 3 4]
  #   [1 # (inc 1) 2]        -> error   but `# (` is a tag, and stays an error
  @conditional_cases [
    {"[1 #?(:clj 2) 3]", "[1 2 3]"},
    {"[1 #?(:cljs 2) 3]", "[1 3]"},
    {"[1 #?(:cljs 2)]", "[1]"},
    {"[#?(:clj 1)]", "[1]"},
    {"[#?(:cljs 1)]", "[]"},
    {"[#?@(:clj [1 2])]", "[1 2]"},
    {"[#?@(:cljs [1 2])]", "[]"},
    {"[1 #?@(:cljs [2 3]) 4]", "[1 4]"},
    {"[1 #?@(:clj [2 3]) 4]", "[1 2 3 4]"},
    {"{:a 1 #?(:cljs :b) 2}", :error},
    {"\#{1 #?(:cljs 2)}", "\#{1}"},
    {"[1 #?(:cljs 2 :default 3) 4]", "[1 3 4]"},
    {"(list 1 #?(:cljs 2) 3)", "(1 3)"},
    {"[#?(:cljs)]", "[]"},
    {"[1 #?(:cljs 2) #?(:cljs 3) 4]", "[1 4]"},
    {"[#?@(:cljs [])]", "[]"},
    {"[#?(:cljs [1 2])]", "[]"},
    {"[1 #? (:cljs 2) 3]", "[1 3]"},
    {"[[1 #?(:cljs 2)] 3]", "[[1] 3]"},
    {"[#?(:cljs 1 :clj 2)]", "[2]"},
    {"[1 #?(:clj 2 :default 3) 4]", "[1 2 4]"},
    {"{:a #?(:cljs 1) :b 2}", :error},
    {"[1 #?(:cljs 2) #?(:clj 3) 4]", "[1 3 4]"},
    {"[#?(:clj)]", :error},
    {"[#?(:cljs)]", "[]"},
    {"[#?(:cljs 1 :clj)]", :error},
    {"[#?(:clj 1 :cljs)]", "[1]"},
    {"[1 #?@ (:cljs [2 3]) 4]", "[1 4]"},
    {"[1 #?@(:clj [2 3]) 4]", "[1 2 3 4]"},
    {"[1 #_ 2 3]", "[1 3]"},
    {"[#_]", :error},
    {"[1 #_ 2]", "[1]"},
    {"[(#(inc 1))]", "[2]"},
    {"[1 # (inc 1) 2]", :error},
    {"[\#{1 2}]", "[\#{1 2}]"},
    {"[1 # {1} 2]", :error},
    {"[1 #?@ ( :clj [2]) 3]", "[1 2 3]"},
    {"[#?()]", "[]"},
    {"[#? ()]", "[]"},
    {"[1 #? () 2]", "[1 2]"},
    {"[1 #?@ () 2]", "[1 2]"},
    {"[1 #? (:cljs 2 :default 3) 4]", "[1 3 4]"},
    {"[1 #?@ (:clj [2]) 3]", "[1 2 3]"},
    {"{:a 1 #?(:clj :b 2)}", :error},
    {"[1 #?(:cljs 2) 3 #?(:clj 4) 5]", "[1 3 4 5]"},
    {"[#?@(:cljs [1]) #?@(:clj [2])]", "[2]"},
  ]

  test "reader-conditional answers match the JVM reader" do
    pr = fn v -> BeamLisp.RT.invoke(BeamLisp.Env.fetch!("core", "pr-str"), [v]) end

    for {src, expected} <- @conditional_cases do
      got =
        try do
          pr.(BeamLisp.Compiler.eval_string(src))
        rescue
          _ -> :error
        catch
          _, _ -> :error
        end

      assert got == expected,
             "reader conditional #{src}: JVM said #{inspect(expected)}, this reader said #{inspect(got)}"
    end
  end
end
