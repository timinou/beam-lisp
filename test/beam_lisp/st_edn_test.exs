defmodule BeamLisp.StEdnTest do
  @moduledoc """
  The EDN⟷Spacetime wire, read and written on the BEAM (verse PLAN-148 W6b).

  There is exactly ONE codec and it lives in verse — two implementations of a
  bijection drift, and the drift is silent. What is tested here is the BEAM's
  half of the contract: that it reads verse's output as ordinary data, and that
  what it writes is the wire verse expects.

  The fixture `test/fixtures/confirm.edn` is REAL verse output
  (`spacetime edn stdlib/__mcp__/kit/confirm.st`), not a hand-written
  approximation — a hand-written fixture would only prove the test agrees with
  itself.
  """

  use ExUnit.Case, async: false

  @codec "spell/src/spell/st-edn.bl"

  defp codec(body), do: BeamLisp.eval(File.read!(@codec) <> "\n" <> body)

  describe "reading verse's output" do
    test "a real document from verse reads as data" do
      doc = File.read!("test/fixtures/confirm.edn")
      assert {:map, pairs} = BeamLisp.Reader.read_one(doc)

      keys = for {{:keyword, k}, _} <- pairs, do: k
      assert "st/imports" in keys
      assert "st/forms" in keys
      assert "st/scopes" in keys
    end

    test "every form in a real document survives as a list" do
      doc = File.read!("test/fixtures/confirm.edn")
      {:map, pairs} = BeamLisp.Reader.read_one(doc)
      {_, {:vector, forms}} = Enum.find(pairs, fn {{:keyword, k}, _} -> k == "st/forms" end)

      # confirm.st is 6 forms: @import, @data inline, @mcp-input(refresh),
      # @mcp-host, and two @mcp-action.
      assert length(forms) == 6
      assert Enum.all?(forms, &match?({:list, [{:symbol, _} | _]}, &1))
    end

    test "a capture's tagged value keeps its shape" do
      # `[:st/expr "\"\""]` must survive as a tagged vector, not decay into a
      # symbol plus a string — that decay is exactly the silent corruption the
      # format rules exist to prevent.
      doc = File.read!("test/fixtures/confirm.edn")
      {:map, pairs} = BeamLisp.Reader.read_one(doc)
      {_, {:vector, forms}} = Enum.find(pairs, fn {{:keyword, k}, _} -> k == "st/forms" end)

      tagged =
        Enum.find_value(forms, fn {:list, items} ->
          Enum.find(items, &match?({:vector, [{:keyword, "st/expr"} | _]}, &1))
        end)

      assert {:vector, [{:keyword, "st/expr"}, value]} = tagged
      assert is_binary(value)
    end

    test "form-macro reads the macro name off a wire form" do
      assert codec(~S|(form-macro '(data-inline :name $x))|) == "data-inline"
    end

    test "form-captures reads the :capture pairs" do
      result = codec(~S|(get (form-captures '(data-inline :name $x :value 0)) "value")|)
      assert result == 0
    end
  end

  describe "writing the wire" do
    test "a form emits in the shape verse reads" do
      # A BINDING is a bare symbol on the wire, not a string: `$mcpPrompt` reads
      # verbatim as a symbol in both readers, and quoting it would decode to
      # `CapturedValue::String` rather than `Binding` — a different capture.
      assert codec(~S|(emit-form "data-inline" {"name" '$mcpPrompt})|) ==
               ~S|(data-inline :name $mcpPrompt)|
    end

    test "a tagged value keeps its keyword AND its quoting" do
      # The bug this pins: building the vector by hand with `str`/`map pr-str`
      # produced `[st/expr 0]` — a symbol and a number, a DIFFERENT value on the
      # way back. `pr-str` recurses correctly, so the printer is used, not
      # reimplemented.
      assert codec(~S|(emit-form "data-inline" {"value" [:st/expr "0"]})|) ==
               ~S|(data-inline :value [:st/expr "0"])|
    end

    test "a document carries its imports with quoting intact" do
      out =
        codec(~S"""
        (emit-document {:imports ["stdlib/__mcp__"]
                        :forms ["(mcp-input)"]})
        """)

      assert out =~ ~S|:st/imports ["stdlib/__mcp__"]|
      assert out =~ ~S|:st/forms [(mcp-input)]|
    end

    test "emitted text reads back through the reader" do
      # The minimum bar for anything claiming to write EDN: what it produces must
      # be readable, not merely plausible.
      out = codec(~S|(emit-form "data-inline" {"name" "$x" "value" [:st/expr "0"]})|)
      assert {:list, [{:symbol, "data-inline"} | _]} = BeamLisp.Reader.read_one(out)
    end

    test "an interface can be GENERATED with ordinary Lisp" do
      # This is the whole reason to have EDN: the interface is a value, so it is
      # built by `map` rather than written by hand.
      out =
        codec(~S"""
        (emit-document
          {:forms (map (fn [i]
                         (emit-form "data-inline"
                                    {"name" (str "$field" i)
                                     "value" [:st/expr (str i)]}))
                       [0 1 2])})
        """)

      assert out =~ "$field0"
      assert out =~ "$field1"
      assert out =~ "$field2"
      assert {:map, _} = BeamLisp.Reader.read_one(out)
    end
  end

  describe "the format rules that exist to prevent silent corruption" do
    test "$binding and &element read verbatim as symbols" do
      assert BeamLisp.Reader.read_one("$mcpPrompt") == {:symbol, "$mcpPrompt"}
      assert BeamLisp.Reader.read_one("&main") == {:symbol, "&main"}
    end

    test "@ is deref here, which is why no form is keyed by @directive" do
      # Keying the wire by macro name is what frees `@` to mean what a Lisp
      # programmer expects. Had the wire used `@data`, this would be ambiguous.
      assert {:list, [{:symbol, "deref"}, {:symbol, "count"}]} =
               BeamLisp.Reader.read_one("@count")
    end

    test "units are vectors because this reader has no EDN tagged literals" do
      assert {:vector, [{:keyword, "st/time"}, 500]} =
               BeamLisp.Reader.read_one("[:st/time 500]")

      # The alternative, `#st/time 500`, reads as TWO forms here — which is why
      # the format uses vectors and needs no reader support anywhere.
      assert_raise BeamLisp.Reader.SyntaxError, ~r/got 2/, fn ->
        BeamLisp.Reader.read_one("#st/time 500")
      end
    end

    test "a typeref is a string because the bare form corrupts silently" do
      # `Message[]` as a bare symbol reads as a symbol plus an empty vector, with
      # NO error — the `[]` is simply lost.
      assert BeamLisp.Reader.read_one(~S|"Message[]"|) == "Message[]"
    end
  end

  describe "cross-runtime parity (requires the verse binary)" do
    @verse Path.expand("~/code/ora/verse")

    setup do
      if File.dir?(@verse), do: :ok, else: {:ok, skip: true}
    end

    @tag :cross_runtime
    test "EDN generated HERE compiles in verse" do
      # The end-to-end claim: an interface built by ordinary Lisp on the BEAM is
      # a program verse accepts. Nothing about the wire is BEAM-specific, and
      # nothing about verse's reader is hand-fed.
      forms =
        codec(~S"""
        (emit-document
          {:forms (map (fn [i]
                         (emit-form "data-inline"
                                    {"name" (str "$field" i)
                                     "value" [:st/expr (str i)]}))
                       [0 1 2])})
        """)

      # Strip the document wrapper: `spacetime st` takes a form sequence.
      #
      # The `:st/imports` key is matched OPTIONALLY. It used to be absent when
      # a caller supplied no imports, and the strip assumed that — so the day
      # `emit-document` started delegating to `print-document` (which always
      # emits the key, because verse accepts an empty vector and a document
      # with no imports key at all is harder to recognise as a mistake), this
      # test fed verse a fragment beginning `:st/imports []` and read the
      # rejection as verse disliking BEAM-generated EDN. The wrapper is ours;
      # the strip should describe all of it.
      body =
        forms
        |> String.replace(~r/^\{(:st\/imports \[[^\]]*\]\s*)?:st\/forms \[/, "")
        |> String.replace(~r/\]\}$/, "")

      path = Path.join(System.tmp_dir!(), "bl_parity_#{System.unique_integer([:positive])}.edn")
      File.write!(path, body)

      try do
        {out, status} =
          System.cmd("cargo", ["run", "--quiet", "--bin", "spacetime", "--", "st", path],
            cd: @verse,
            stderr_to_stdout: false
          )

        assert status == 0, "verse rejected BEAM-generated EDN:\n#{out}"
        assert out =~ "@data inline $field0"
        assert out =~ "@data inline $field1"
        assert out =~ "@data inline $field2"
      after
        File.rm(path)
      end
    end
  end
end
