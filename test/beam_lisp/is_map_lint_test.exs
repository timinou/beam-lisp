defmodule BeamLisp.IsMapLintTest do
  # Source-level lint, NOT a runtime check: this file never evaluates any
  # beam-lisp source, so it is safe to run concurrently with the rest of the
  # suite (`async: true`).
  use ExUnit.Case, async: true

  @moduledoc """
  Enforces the "struct is a map" invariant at the source level.

  On the BEAM a struct IS a map: `is_map(%BeamLisp.Vector{})` is `true`,
  because a struct is a map carrying a `:__struct__` key. beam-lisp has 11
  struct kinds (Vector, Set, LazySeq, the references Atom/Ref/Volatile/
  Agent/Task, Transient, and user records) that must never take a
  "beam-lisp map" collection path. Collection fns in `BeamLisp.RT` guard
  their plain-map clauses with `BeamLisp.Guards.is_bl_map/1`; the genuine
  exceptions are annotated `# is_map-ok: <reason>`.

  Nothing previously prevented someone reintroducing a bare `is_map(` — and
  "a moduledoc is a claim, not proof": 38 of 40 sites had decayed before the
  guards landed. This test scans every `.ex` under `lib/` and fails on any
  bare `is_map(` that is not one of the sanctioned forms, so the NEXT
  contributor (or agent that has never read the bug report) trips on it the
  moment they reintroduce the footgun.

  The rule, deliberately:
    * `is_map(x) and not is_struct(x)` — the correct inline form — is fine.
    * `lib/beam_lisp/guards.ex` is where `is_bl_map/1` is DEFINED; exempt.
    * an `# is_map-ok: <reason>` comment on the line or within the ~3 lines
      above marks a deliberate "any map, structs included" call site.
    * `is_map` mentioned inside a comment, moduledoc, or heredoc string is
      prose, not code — never flagged.
    * `not is_map(x)` is SAFE and deliberately not flagged: it asserts the
      argument is NOT a map, and since every struct IS a map it can never
      admit a struct onto a map path. The footgun is only the positive test
      `is_map(x)` that swallows structs. Negation is a documented decision,
      not an oversight.
    * `is_map_key/2` is a different Erlang guard; `is_bl_map(` is the guard
      this lint protects — neither is `is_map(`, so neither matches.
  """

  # ------------------------------------------------------------------
  # The checker. Pure over {filename, source_string} → [violation].
  # Kept here, beside its tests, so the rule lives with its proof;
  # lifting it into a mix task later is a mechanical copy.
  # ------------------------------------------------------------------

  @doc """
  Returns every unsanctioned `is_map(` in `source` as a list of
  `%{file: filename, line: n, text: raw_line}`.
  """
  def violations({filename, source}) do
    # The guard is *defined* in this file; its own `is_map(x) and not
    # is_struct(x)` is the canonical inline form and must not be reported.
    if guard_definition_file?(filename) do
      []
    else
      lines = String.split(source, "\n")
      masked = mask_comments_and_strings(lines)

      lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {raw, n} ->
        code = Enum.at(masked, n - 1)

        code
        |> is_map_call_indexes()
        |> Enum.filter(fn idx -> not exempt?(masked, lines, n, idx) end)
        |> Enum.map(fn _ -> %{file: filename, line: n, text: raw} end)
      end)
    end
  end

  # Only `lib/beam_lisp/guards.ex` — the canonical definition — is exempt.
  defp guard_definition_file?(filename),
    do: Regex.match?(~r{(^|/)lib/beam_lisp/guards\.ex$}, filename)

  # Every `is_map(` byte index in the code-only view of a line. Note the
  # token is `is_map` *immediately* followed by `(` — so `is_map_key(`
  # (which reads `is_map_key(`) and `is_bl_map(` (which reads `is_bl_map(`)
  # never match here by construction.
  defp is_map_call_indexes(code) do
    # Regex.scan/3 is `scan(regex, string, options)` -- the code line is the
    # SECOND arg; the pipe would wrongly make it the first. Write it out.
    Regex.scan(~r/is_map\(/, code, return: :index)
    |> Enum.map(fn [{pos, _len}] -> pos end)
  end

  defp exempt?(masked, lines, n, idx) do
    negation?(Enum.at(masked, n - 1), idx) or
      inline_conjunction?(masked, n, idx) or
      ok_comment?(lines, n)
  end

  # `not is_map(x)` / `not(is_map(x))` — negation, safe (see moduledoc).
  defp negation?(code, idx) do
    prefix = binary_part(code, 0, idx)
    Regex.match?(~r/not\s*\(?\s*$/, prefix)
  end

  # The correct inline form, `is_map(x) and not is_struct(x)`, possibly with
  # the conjunction wrapped across lines. Look forward up to 3 lines and
  # match anchored at the call site so only THIS `is_map(` is checked.
  defp inline_conjunction?(masked, n, idx) do
    forward =
      masked
      |> Enum.drop(n - 1)
      |> Enum.take(3)
      |> Enum.join(" ")

    from = binary_part(forward, idx, byte_size(forward) - idx)
    Regex.match?(~r/\Ais_map\([^)]*\)\s+and\s+not\s+is_struct\(/, from)
  end

  # An `# is_map-ok:` comment on the line itself or any of the ~3 lines
  # directly above (the existing exemptions put it there; e.g. compiler.ex,
  # meta.ex, form_meta.ex all span 0–3 lines).
  defp ok_comment?(lines, n) do
    lines
    |> Enum.slice(max(n - 4, 0), 4)
    |> Enum.any?(&String.contains?(&1, "is_map-ok:"))
  end

  # ------------------------------------------------------------------
  # Comment / string masking.
  #
  # We only want to scan *code*. `is_map(` in a comment, a `@moduledoc`,
  # or any string literal is prose and must not trip the lint. Mask every
  # such span to spaces while preserving newlines (so line numbers hold),
  # then scan the masked text.
  # ------------------------------------------------------------------

  defp mask_comments_and_strings(lines) do
    lines
    |> Enum.join("\n")
    |> mask()
    |> String.split("\n")
  end

  defp mask(source) do
    source
    |> String.to_charlist()
    |> do_mask(:code)
    |> List.to_string()
  end

  # :code — normal text; `#` opens a comment, `"""` a heredoc, `"` a string.
  defp do_mask([?", ?", ?" | rest], :code),
    do: [?\s, ?\s, ?\s | do_mask(rest, :heredoc)]

  defp do_mask([?# | rest], :code), do: [?\s | do_mask(rest, :comment)]
  defp do_mask([?" | rest], :code), do: [?\s | do_mask(rest, :string)]

  defp do_mask([c | rest], :code), do: [c | do_mask(rest, :code)]

  # :comment — through end of line (newline returns to :code).
  defp do_mask([?\n | rest], :comment), do: [?\n | do_mask(rest, :code)]
  defp do_mask([_c | rest], :comment), do: [?\s | do_mask(rest, :comment)]

  # :string — a `"..."` literal; `\"` is escaped, newline is preserved
  # defensively (a real Elixir string cannot span lines).
  defp do_mask([?\\, ?" | rest], :string), do: [?\s, ?\s | do_mask(rest, :string)]
  defp do_mask([c | rest], :string) when c in [?\n, ?"], do: [c | do_mask(rest, :code)]
  defp do_mask([_c | rest], :string), do: [?\s | do_mask(rest, :string)]

  # :heredoc — a `"""..."""` moduledoc/docstring; newlines preserved.
  defp do_mask([?", ?", ?" | rest], :heredoc), do: [?\s, ?\s, ?\s | do_mask(rest, :code)]
  defp do_mask([c | rest], :heredoc) when c == ?\n, do: [c | do_mask(rest, :heredoc)]
  defp do_mask([_c | rest], :heredoc), do: [?\s | do_mask(rest, :heredoc)]

  # End of input -- every state terminates here.
  defp do_mask([], _state), do: []

  # ------------------------------------------------------------------
  # Failure rendering — written for the 2am reader with no context.
  # ------------------------------------------------------------------

  defp render([]), do: ""

  defp render(violations) do
    Enum.map_join(violations, "\n\n", &render_one/1)
  end

  defp render_one(v) do
    """
    #{v.file}:#{v.line}
        #{String.trim(v.text)}

    is_map/1 is true for EVERY struct -- a struct is a map carrying a
    :__struct__ key. beam-lisp has 11 struct types (Vector, Set, LazySeq,
    Atom, Ref, Volatile, Agent, Task, Transient, records) that must never
    take a "beam-lisp map" path.

      * If you mean "a beam-lisp map": use BeamLisp.Guards.is_bl_map/1.
      * If you genuinely mean "any map, structs included": add a comment
        `# is_map-ok: <why this accepts structs too>` above or on the line.
    """
  end

  # ------------------------------------------------------------------
  # Unit tests — the rule, proven on fixture strings without touching lib/.
  # ------------------------------------------------------------------

  test "bare is_map( is flagged" do
    src = "def f(x) when is_map(x), do: x\n"
    assert [%{file: "foo.ex", line: 1, text: "def f(x) when is_map(x), do: x"}] = violations({"foo.ex", src})
  end

  test "bare is_map( on a later line reports the right line number" do
    src = """
    defmodule Foo do
      def f(x) when is_map(x), do: x
    end
    """

    assert [%{file: "foo.ex", line: 2}] = violations({"foo.ex", src})
  end

  test "inline conjunction is_map(x) and not is_struct(x) is not flagged" do
    src = "def f(x) when is_map(x) and not is_struct(x), do: x\n"
    assert [] = violations({"foo.ex", src})
  end

  test "multi-line conjunction (and\\n not is_struct) is not flagged" do
    src = """
    def f(x) when is_map(x) and
        not is_struct(x), do: x
    """

    assert [] = violations({"foo.ex", src})
  end

  test "is_map-ok: comment on the same line is not flagged" do
    src = "def f(x) when is_map(x), do: x # is_map-ok: internal meta map\n"
    assert [] = violations({"foo.ex", src})
  end

  test "is_map-ok: comment on the directly preceding line is not flagged" do
    src = "# is_map-ok: internal meta map\n" <> "def f(x) when is_map(x), do: x\n"
    assert [] = violations({"foo.ex", src})
  end

  test "is_map-ok: comment up to three lines above is not flagged" do
    src = """
    # is_map-ok: reader position map (:line/:col/:file), never user data
    # -- two blank-ish comment lines between the reason and the call.
    defp pos_env(env, m) when is_map(m) do
      env
    end
    """

    assert [] = violations({"foo.ex", src})
  end

  test "is_map_key/2 is a different guard and is not flagged" do
    src = "def f(k, m) when is_map_key(k, m), do: :ok\n"
    assert [] = violations({"foo.ex", src})
  end

  test "is_bl_map( is the guard this lint protects and is not flagged" do
    src = "def f(x) when is_bl_map(x), do: x\n"
    assert [] = violations({"foo.ex", src})
  end

  test "not is_map(x) is safe (excludes structs too) and is not flagged" do
    # Documented decision: negation can never admit a struct onto a map
    # path, so it is not the footgun — see the moduledoc.
    src = "def f(x) when not is_map(x), do: :not_map\n"
    assert [] = violations({"foo.ex", src})
  end

  test "is_map( in lib/beam_lisp/guards.ex (where the guard is defined) is exempt" do
    src = "defguard is_bl_map(x) when is_map(x) and not is_struct(x)\n"
    assert [] = violations({"lib/beam_lisp/guards.ex", src})
  end

  test "the guards.ex exemption is keyed on the filename, not the content" do
    # Rule 2 exempts the whole definition file; the SAME source under a
    # different name is still fully checked.
    src = "defguard is_bl_map(x) when is_map(x) and not is_struct(x)\n" <> "def g(y) when is_map(y), do: y\n"
    assert [] = violations({"lib/beam_lisp/guards.ex", src})
    assert [%{line: 2}] = violations({"some/other.ex", src})
  end

  test "is_map( inside a moduledoc is prose, not code, and is not flagged" do
    src = """
    defmodule Foo do
      @moduledoc \"\"\"
      is_map(%BeamLisp.Vector{}) is true because a struct is a map with a
      :__struct__ key, so is_map( alone cannot tell them apart.
      \"\"\"

      def f(x) when is_struct(x), do: x
    end
    """

    assert [] = violations({"foo.ex", src})
  end

  test "is_map( inside an inline comment is prose and is not flagged" do
    src = "# never call is_map( on user data\n" <> "def f(x), do: x\n"
    assert [] = violations({"foo.ex", src})
  end

  test "is_map( inside a regular string literal is not flagged" do
    src = "msg = \"is_map( on a struct returns true\"\n"
    assert [] = violations({"foo.ex", src})
  end

  test "a moduledoc mentioning is_map( does not mask a real violation elsewhere in the file" do
    src = """
    defmodule Foo do
      @moduledoc \"\"\"
      is_map( is the footgun; prefer is_bl_map/1.
      \"\"\"

      def f(x) when is_map(x), do: x
    end
    """

    assert [%{line: 6}] = violations({"foo.ex", src})
  end

  test "the rendered failure names the file, line, text, hazard and both remedies" do
    v = violations({"foo.ex", "def f(x) when is_map(x), do: x\n"})
    msg = render(v)

    assert msg =~ "foo.ex:1"
    assert msg =~ "def f(x) when is_map(x), do: x"
    assert msg =~ "is_map/1 is true for EVERY struct"
    assert msg =~ "use BeamLisp.Guards.is_bl_map/1"
    assert msg =~ "is_map-ok:"
  end

  # ------------------------------------------------------------------
  # End-to-end: the enforcement against the real tree. Every `.ex` under
  # lib/ must be clean; a new module is covered automatically by the walk.
  # ------------------------------------------------------------------

  test "every bare is_map( in lib/ is sanctioned" do
    files = Path.wildcard("lib/**/*.ex")

    violations =
      Enum.flat_map(files, fn file ->
        violations({file, File.read!(file)})
      end)

    assert violations == [], render(violations)
  end
end
