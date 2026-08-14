# scripts/machine_check.exs — the ghost-selector check, asked of the COMPILER.
#
# `machine.bl` answers every question it can from the terms themselves. One
# question it must NOT answer that way: "does an element with this class exist?"
#
# Our templates are strings we generated. A scan over them agrees with our
# emitter by construction — it would have reported `.log` as rendered while the
# page had no `.log` at all, which is the exact failure this project already
# shipped once. The only independent authority is verse: it compiles the markup
# into `registerTemplate` calls in the emitted JS, and the styles into CSS.
#
#   styled  = selectors present in `inspect --layer emit` → css.content
#   rendered = class tokens present in                   → js.content
#   ghosts  = styled − rendered
#
# Verified discriminating (see PLAN-023): on a page styling `.real`,
# `.ghost-never-exists` and `.also-missing__elem`, only `.real` appears in the
# emitted JS. `spacetime check --deny-warnings` exits 0 on that page — there is
# no diagnostic for this, which is why the check lives here.
#
# Usage:  mix run scripts/machine_check.exs <file.st>
#         exit 0 = no ghosts, 1 = ghosts found (names printed)

defmodule MachineCheck do
  @verse Path.expand("~/code/ora/verse")

  def emit_layers(st_file) do
    abs = Path.expand(st_file)

    {out, code} =
      System.cmd(
        "cargo",
        ["run", "-q", "--bin", "spacetime", "--", "inspect", "--layer", "emit", "--format",
         "json", abs],
        cd: @verse,
        # cargo's build chatter goes to stderr; keeping the streams SEPARATE is
        # what lets us parse stdout as JSON. Merging them (the usual reflex)
        # makes `Jason.decode` fail on rustc warnings.
        stderr_to_stdout: false
      )

    if code != 0 do
      raise "spacetime inspect failed (exit #{code}) on #{abs}"
    end

    case Jason.decode(out) do
      {:ok, %{"css" => %{"content" => css}, "js" => %{"content" => js}}} ->
        {css, js}

      {:ok, other} ->
        raise "unexpected inspect shape: #{inspect(Map.keys(other))}"

      {:error, e} ->
        raise "inspect did not return JSON: #{Exception.message(e)}"
    end
  end

  @doc """
  Class tokens named by CSS selectors.

  Deliberately conservative: it takes the class tokens out of each selector,
  so `.bubble[data-role='user']` contributes `bubble`. An attribute-only or
  element-only selector (`body`, `.a > span`) contributes what classes it has
  and nothing else — the point is to catch a class nothing renders, not to
  reimplement selector matching.
  """
  def styled_classes(css) do
    Regex.scan(~r/^\s*([^{}\n][^{}]*)\{/m, css)
    |> Enum.map(fn [_, sel] -> sel end)
    |> Enum.flat_map(fn sel ->
      Regex.scan(~r/\.([A-Za-z_][-\w]*)/, sel) |> Enum.map(fn [_, c] -> c end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Class tokens the compiler actually put into rendered markup.

  Read out of the emitted JS rather than our source templates: this is the
  independent half of the check.
  """
  def rendered_classes(js) do
    Regex.scan(~r/class=\\?['"]([^'"\\]*)/, js)
    |> Enum.flat_map(fn [_, c] -> String.split(c, ~r/\s+/, trim: true) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def ghosts(st_file) do
    {css, js} = emit_layers(st_file)
    styled = styled_classes(css)
    rendered = rendered_classes(js)
    {styled -- rendered, styled, rendered}
  end

  def main([st_file]) do
    {ghosts, styled, rendered} = ghosts(st_file)

    IO.puts("styled classes   : #{length(styled)}")
    IO.puts("rendered classes : #{length(rendered)}")

    if ghosts == [] do
      IO.puts("\n✓ no ghost selectors — every styled class is rendered by some template")
      System.halt(0)
    else
      IO.puts("\n✗ #{length(ghosts)} styled class(es) that NO template renders:")
      Enum.each(ghosts, fn g -> IO.puts("    .#{g}") end)
      IO.puts("\nCSS does not create DOM. A rule matching nothing is silent.")
      System.halt(1)
    end
  end

  def main(_) do
    IO.puts("usage: mix run scripts/machine_check.exs <file.st>")
    System.halt(2)
  end
end

MachineCheck.main(System.argv())
