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
end
