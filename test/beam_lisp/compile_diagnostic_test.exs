defmodule BeamLisp.CompileDiagnosticTest do
  @moduledoc """
  Two properties, both regressions that mattered:

    1. `(try body (finally cleanup))` — a try with a finally and NO catch —
       compiles and runs. The self-hosted compiler used to build the catch
       clause eagerly from `(first catches)`, so an empty catch list passed
       `nil` into `node-items` and crashed with a bare `not a tuple`. This is
       valid, common code (every `with-target`-style resource guard uses it).

    2. When the compiler DOES crash on a user form, the error names the source:
       file, line, the offending construct, and the cause — never a bare
       Erlang `badarg` that points at nothing. `BeamLisp.CompileDiagnostic`
       renders that report; here we assert its shape directly (it must not
       depend on which form happened to trip the compiler).
  """

  use ExUnit.Case, async: false

  setup do
    BeamLisp.init()
    :ok
  end

  defp eval(source), do: BeamLisp.Compiler.eval_string(source)

  describe "try/finally without a catch (the empty-catches regression)" do
    test "a finally with no catch runs the body and the cleanup" do
      # The finally must fire and the body's value must be returned. We prove
      # the finally ran by its side effect on a process-dictionary key.
      assert eval("""
             (erlang/put :diag-test-ran false)
             (def result
               (try
                 42
                 (finally (erlang/put :diag-test-ran true))))
             [result (erlang/get :diag-test-ran)]
             """) == BeamLisp.Vector.new([42, true])
    end

    test "a finally still runs when the body throws" do
      # The body throws; the finally must still fire, then the throw propagates.
      # beam-lisp's `(throw v)` surfaces as a raised `BeamLisp.ExInfo`, so the
      # propagation is a raise, not an Erlang throw — and the diagnostic wrapper
      # must let it through unchanged (a runtime throw is not a compile error).
      assert_raise BeamLisp.ExInfo, fn ->
        eval("""
        (erlang/put :diag-finally-ran false)
        (try
          (throw :boom)
          (finally (erlang/put :diag-finally-ran true)))
        """)
      end

      # the finally fired before the throw propagated
      assert BeamLisp.eval("(erlang/get :diag-finally-ran)") == true
    end

    test "a catch still works alongside a finally" do
      # Both present: the catch handles the throw, the finally still runs.
      assert eval("""
             (erlang/put :diag-both-ran false)
             (try
               (throw :handled)
               (catch e :caught)
               (finally (erlang/put :diag-both-ran true)))
             """) == :caught

      assert BeamLisp.eval("(erlang/get :diag-both-ran)") == true
    end

    test "a bare catch (no finally) still works" do
      assert eval("(try (throw :x) (catch e :recovered))") == :recovered
    end
  end

  describe "the diagnostic renderer names the source" do
    test "a compiler crash reports file:line, the construct, a cause, and the form" do
      form = {:meta, {:list, [{:symbol, "try"}]}, %{line: 7, col: 3, file: "demo.bl"}}
      exception = %ArgumentError{message: "errors were found at the given arguments:\n\n  * 1st argument: not a tuple"}
      stacktrace = [{BeamLisp.Ns.Fn.M1, :"node-items", 1, [file: ~c"reader-node.bl", line: 67]}]

      report =
        BeamLisp.CompileDiagnostic.render(form, exception, stacktrace,
          source: "line1\nline2\nline3\nline4\nline5\nline6\n(try)\n",
          phase: "compiling"
        )

      # location
      assert report =~ "demo.bl:7:3"
      # the construct in play, by name
      assert report =~ "`try`"
      # the cause is translated, not left as a bare badarg
      assert report =~ "wrong shape"
      # the deepest compiler frame is named
      assert report =~ "node-items"
      # a source snippet with a caret
      assert report =~ "7 | (try)"
      assert report =~ "^"
    end

    test "a deliberate CompileError passes through with_diagnostic untouched" do
      form = {:meta, {:list, [{:symbol, "ns"}]}, %{line: 1, col: 1, file: "x.bl"}}

      original =
        BeamLisp.CompileError.exception(
          message: "ns supports only :require clauses",
          file: "x.bl",
          line: 1
        )

      raised =
        assert_raise BeamLisp.CompileError, fn ->
          BeamLisp.CompileDiagnostic.with_diagnostic(form, [file: "x.bl"], fn ->
            raise original
          end)
        end

      # the wording is preserved (not re-wrapped into the generic renderer)
      assert raised.message =~ "ns supports only :require clauses"
    end

    test "with_diagnostic turns a raw crash into a located CompileError" do
      form = {:meta, {:list, [{:symbol, "try"}]}, %{line: 9, col: 2, file: "y.bl"}}

      raised =
        assert_raise BeamLisp.CompileError, fn ->
          BeamLisp.CompileDiagnostic.with_diagnostic(form, [file: "y.bl", source: "a\n"], fn ->
            :erlang.tuple_to_list(nil)
          end)
        end

      assert raised.file == "y.bl"
      assert raised.line == 9
      assert raised.message =~ "y.bl:9"
      assert raised.message =~ "`try`"
    end
  end
end
