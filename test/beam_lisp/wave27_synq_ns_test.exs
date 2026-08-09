defmodule BeamLisp.Wave27SynqNsTest do
  @moduledoc """
  Syntax-quote resolves symbols in the namespace that WROTE the template, and
  emits them qualified — as Clojure does.

  Without this, a macro could not call its own helper. Expanding `(helper x)`
  at a call site in another namespace produced a bare `helper`, which then
  resolved against the CALLER and failed with "undefined var:
  caller-ns/helper". That is the ordinary shape of every library macro, so the
  gap was reachable by anyone writing one — it was found by loading Specter's
  navigator stack across namespaces, but nothing about it is Specter-specific.

  The subtlety is what must NOT be qualified:

    * a **macro** — the expander (`macro_for/2`) already searches the writing
      namespace and core. Qualifying one sent it down the ordinary var path
      where it was invoked as a function, which broke every vendored jank
      macro that nests `when` or `let` inside its template.
    * a **gensym** (`x#`) — already unique by construction.
    * a name the template **introduces** (a `let` binding, a fn parameter, a
      var defined later) — it has no meaning in the writing namespace and must
      resolve at the expansion site.
    * a **special form** — not a var at all.
  """
  use ExUnit.Case, async: false

  setup do
    BeamLisp.init()
    BeamLisp.Env.in_ns("user")
    :ok
  end

  defp eval(ns, code) do
    case BeamLisp.Compiler.eval_string(code, BeamLisp.Compiler.new_env(ns)) do
      {v, _env} -> v
      v -> v
    end
  end

  test "a macro can call its own helper from another namespace" do
    # The whole point. Before the fix this raised "undefined var: synqapp/mult".
    eval("user", "(ns synqlib)")
    eval("synqlib", "(defn mult [x] (* x 100))")
    eval("synqlib", "(defmacro use-mult [v] `(mult ~v))")

    eval("user", "(ns synqapp)")
    assert eval("synqapp", "(synqlib/use-mult 5)") == 500
  end

  test "a helper defined AFTER the macro still resolves" do
    # Qualification is decided when the template is compiled, so a helper the
    # library defines later must still be reachable. `declare` is the usual
    # way to say so.
    eval("user", "(ns synqlib2)")
    eval("synqlib2", "(declare later-helper)")
    eval("synqlib2", "(defmacro use-later [v] `(later-helper ~v))")
    eval("synqlib2", "(defn later-helper [x] (+ x 7))")

    eval("user", "(ns synqapp2)")
    assert eval("synqapp2", "(synqlib2/use-later 1)") == 8
  end

  test "a template's own bindings are not qualified" do
    # `t` is introduced by the template. Qualifying it would produce
    # `lib/t`, which is not a binding at all.
    eval("user", "(ns synqlib3)")
    eval("synqlib3", "(defmacro twice [v] `(let [t# ~v] (+ t# t#)))")

    eval("user", "(ns synqapp3)")
    assert eval("synqapp3", "(synqlib3/twice 21)") == 42
  end

  test "a macro nested in a template still expands" do
    # This is the regression that the vendored jank macro slices caught.
    eval("user", "(ns synqlib4)")
    eval("synqlib4", "(defmacro pos-only [v] `(when (> ~v 0) :positive))")

    eval("user", "(ns synqapp4)")
    assert eval("synqapp4", "(synqlib4/pos-only 5)") == :positive
    assert eval("synqapp4", "(synqlib4/pos-only -5)") == nil
  end

  test "a core function used in a template resolves from the call site" do
    eval("user", "(ns synqlib5)")
    eval("synqlib5", "(defmacro doubled [v] `(* 2 ~v))")

    eval("user", "(ns synqapp5)")
    assert eval("synqapp5", "(synqlib5/doubled 4)") == 8
  end

  test "the caller's own binding of the same name does not capture the helper" do
    # The real hygiene payoff: the caller has a LOCAL named `shadow`, and the
    # macro's template refers to its own `shadow`. Unqualified, the expansion
    # would silently pick up the caller's.
    eval("user", "(ns synqlib6)")
    eval("synqlib6", "(defn shadow [x] (* x 10))")
    eval("synqlib6", "(defmacro use-shadow [v] `(shadow ~v))")

    eval("user", "(ns synqapp6)")
    eval("synqapp6", "(defn shadow [x] :WRONG)")
    assert eval("synqapp6", "(synqlib6/use-shadow 3)") == 30
  end
end
