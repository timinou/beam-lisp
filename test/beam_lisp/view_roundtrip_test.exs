defmodule BeamLisp.ViewRoundtripTest do
  use ExUnit.Case, async: false

  # Does the emitted view say what we think it says?
  #
  # ── why this file exists
  #
  # test/bl/view_test.bl asserts the emitter's OUTPUT: that `(template …)`
  # appears, that a hole becomes `` `$m.text` ``, that a signal call carries
  # `"signal"`. Every one of those assertions passed while the emitted page was
  # broken in four separate ways, because they all compare the emitter against
  # the shape the emitter meant to produce. An invented key is self-consistent.
  #
  # The four defects, all found in one sitting by printing a document back:
  #
  #   1. templates had BODIES but no DECLARATIONS — `@each` invoked a template
  #      the file never declared
  #   2. holes used `[:st/hole N]` (the `:st/html` plane's spelling) inside a
  #      template body, printing `data-role=[:st/hole 0]`
  #   3. `each` named its template with a bare symbol, printing
  #      `@each(…) { [$m] bubble }` — the invocation inverted
  #   4. a signal call used invented keys `"call"`/`"target"`, printing
  #      `$.($draft,)` — a call with no callee
  #
  # None of them failed a test. All four parsed. Three produced `.st` that was
  # syntactically fine and semantically empty.
  #
  # So the assertion here is not about shape at all. It runs the document
  # through `spacetime st` — the printer, the one component whose whole job is
  # to say what a document MEANS — and then re-parses that output and counts
  # what survived. A form that round-trips is a form the compiler agrees exists.
  #
  # ── why the printer, given that the printer is not on the compile path
  #
  # `to_st_file` (the compile path) is deliberately printer-free, and it
  # accepted all four broken documents: it built an `StFile` whose forms were
  # nonsense but whose STRUCTURE was valid. The printer is what renders meaning
  # back into a surface a human — or a re-parse — can check. That is exactly the
  # property a generated document needs and the reason this test is worth the
  # dependency on the binary.

  @verse Path.expand("~/code/ora/verse")

  setup_all do
    unless File.dir?(@verse) do
      raise "verse checkout not found at #{@verse}"
    end

    :ok
  end

  defp emit_view do
    BeamLisp.Spell.init!()

    BeamLisp.Compiler.eval_string("(spell.seed/view-page)")
  end

  defp print_back(edn) do
    path = Path.join(System.tmp_dir!(), "view_roundtrip_#{System.unique_integer([:positive])}.edn")
    File.write!(path, edn)

    try do
      {out, status} =
        System.cmd("cargo", ["run", "--quiet", "--bin", "spacetime", "--", "st", path],
          cd: @verse,
          stderr_to_stdout: false
        )

      assert status == 0, "spacetime st rejected the emitted document"
      out
    after
      File.rm(path)
    end
  end

  @tag :verse
  @tag timeout: 600_000
  test "the emitted view prints back as the page it claims to be" do
    printed = emit_view() |> print_back()

    # Every template DECLARED, with its parens — `@template &shell { … }`
    # re-parses to zero matches, silently dropping the declaration.
    assert printed =~ "@template &shell()"
    assert printed =~ "@template &bubble($m)"
    assert printed =~ "@template &thinking()"

    # Holes interpolate rather than appearing as literal markers.
    assert printed =~ "`$m.role`"
    assert printed =~ "`$m.text`"
    refute printed =~ ":st/hole", "a hole marker leaked into a template body:\n#{printed}"

    # The `@each` invokes the template by name.
    assert printed =~ "&bubble(", "the each invocation lost its template:\n#{printed}"
    refute printed =~ "[$m] bubble", "the invocation printed inverted:\n#{printed}"

    # The click handler calls a signal that HAS a name.
    assert printed =~ "$send", "the send signal lost its callee:\n#{printed}"
    refute printed =~ "$.(", "a call with no callee:\n#{printed}"

    # The input writes what the user typed somewhere the server can see.
    assert printed =~ "$draft <- $.value"
  end

  @tag :verse
  @tag timeout: 600_000
  test "every form in the emitted view survives a round trip" do
    # The counting property, which is what caught defect 1: three templates
    # went in and one came back, because the two zero-parameter ones printed
    # without parens and re-parsed to nothing.
    #
    # `spacetime st` is fed its own output; a form that cannot survive that is a
    # form the compiler will not see.
    printed = emit_view() |> print_back()

    src = Path.join(System.tmp_dir!(), "view_roundtrip_#{System.unique_integer([:positive])}.st")
    File.write!(src, printed)

    try do
      {edn, status} =
        System.cmd("cargo", ["run", "--quiet", "--bin", "spacetime", "--", "edn", src],
          cd: @verse,
          stderr_to_stdout: false
        )

      assert status == 0, "the printed .st did not re-parse:\n#{printed}"

      # 3 templates + 1 each + 2 on-driver-body = 6 forms, and all three
      # template BODIES still present as constructs.
      assert length(String.split(edn, "(template ")) - 1 == 3,
             "a template declaration was lost:\n#{edn}"

      assert length(String.split(edn, "(on-driver-body")) - 1 == 2,
             "a bind was lost:\n#{edn}"

      assert String.contains?(edn, "(each "), "the each form was lost:\n#{edn}"
    after
      File.rm(src)
    end
  end
end
