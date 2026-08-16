defmodule BeamLisp.Spell.PageRenderTest do
  @moduledoc """
  The preamble a running server supplies, and the module names it points at.

  `BeamLisp.Spell.Page.emit/3` does two things: it asks the machine for five
  values, and it renders a page around them. Only the second is testable
  without a compiler — `emit` shells out to `spacetime st` to print the EDN —
  so this suite exercises the rendering half directly and leaves the subprocess
  to the machine-level checks.

  ## Why the preamble is worth its own suite

  Two lines above the emitted marker decide whether the page is wired to
  anything at all:

    * `@host $chat-live : live("SpellWeb.ChatLive")` — the seam says
      `from $chat-live`, so a page declaring some other host name leaves every
      data source unbound. Verse reports that as W0201 "defined but never
      used", which reads like dead code and actually means nothing is connected.
    * `@data inline $draft : "";` — a page-local the browser writes. Missing,
      the page references an undeclared signal.

  Both are DERIVED, and the derivation is what is pinned here.
  """

  use ExUnit.Case, async: false
  use BeamLisp.SpellCase

  alias BeamLisp.Spell.Page

  # `render/6` is private, and deliberately so — the module's public surface is
  # "write the page". Reaching it through the module's own compiled name keeps
  # the test honest about that: it is testing an internal, and a refactor that
  # renames it should break this file loudly rather than silently stop covering
  # it.
  defp render(seam, view, locals, hosts, css, prefix \\ "SpellWeb") do
    apply(Page, :render, [seam, view, locals, hosts, css, prefix])
  rescue
    UndefinedFunctionError ->
      flunk("Page.render/6 is gone — the page preamble moved and this suite must follow it")
  end

  describe "hosts" do
    test "a kebab-case contract becomes a CamelCase LiveView module" do
      page = render("", "", [], ["chat-live"], "")
      assert page =~ ~s|@host $chat-live : live("SpellWeb.ChatLive")|
    end

    test "an acronym keeps its case" do
      # `String.capitalize/1` was the obvious implementation and it lowercases
      # the rest of a segment: a contract named `HTTP-live`, whose seam says
      # `from $HTTP-live` and whose module is `HTTPLive`, would get a page
      # pointing at `HttpLive` — a module the contract does not describe.
      page = render("", "", [], ["HTTP-live"], "")
      assert page =~ ~s|@host $HTTP-live : live("SpellWeb.HTTPLive")|
      refute page =~ "HttpLive"
    end

    test "the module name agrees with the contract emitter, character for character" do
      # Two implementations of one naming rule: `Page.module_name/1` (private)
      # and `spell.contract/module-name`. When they disagree, the page declares
      # a host whose module the generated LiveView does not define, and the
      # failure surfaces in a browser as a page that connects to nothing.
      module_name = fetch!("spell.contract", "module-name")

      for host <- ["chat-live", "HTTP-live", "clock", "a-b-c"] do
        contract = %{name: host}
        expected = module_name.(contract, "SpellWeb")
        assert render("", "", [], [host], "") =~ ~s|live("#{expected}")|,
               "Page and spell.contract disagree about the module for #{host}"
      end
    end

    test "several contracts each get a line" do
      page = render("", "", [], ["chat-live", "clock-live"], "")
      assert page =~ ~s|@host $chat-live : live("SpellWeb.ChatLive")|
      assert page =~ ~s|@host $clock-live : live("SpellWeb.ClockLive")|
    end

    test "the prefix is honoured" do
      page = render("", "", [], ["chat-live"], "", "OtherWeb")
      assert page =~ ~s|live("OtherWeb.ChatLive")|
    end
  end

  describe "page-locals" do
    test "each local is declared inline and empty" do
      page = render("", "", ["draft"], [], "")
      assert page =~ ~s|@data inline $draft : "";|
    end

    test "no locals means no declarations, not an empty one" do
      page = render("", "", [], [], "")
      refute page =~ "@data inline"
    end
  end

  describe "the emitted body" do
    test "seam, views and style each land below the marker, in order" do
      page = render("SEAM_HERE", "VIEW_HERE", [], [], "CSS_HERE")

      marker = index_of(page, "emitted: the seam")
      assert marker

      for token <- ~w(SEAM_HERE VIEW_HERE CSS_HERE) do
        assert index_of(page, token) > marker,
               "#{token} rendered above the marker, where the SERVER's half lives"
      end

      assert index_of(page, "SEAM_HERE") < index_of(page, "VIEW_HERE")
      assert index_of(page, "VIEW_HERE") < index_of(page, "CSS_HERE")
    end

    test "the stdlib imports the emitted forms need are all present" do
      # An `@each` needs `each`, an `@on` needs `on`, a `@view` needs
      # `enum/dispatch`. A missing import is an EDN reader error at the moment
      # a model first proposes the construct that needs it — long after the
      # definition looked accepted.
      page = render("", "", [], [], "")

      for import <- ~w(data-kind each on host handle) do
        assert page =~ ~s|@import "stdlib/macros/#{import}"|
      end

      assert page =~ ~s|@import "stdlib/enum/dispatch"|
    end
  end

  describe "the whole page, from the seeded machine" do
    test "every host it declares is a contract the machine registered" do
      hosts = plain(fetch!("spell.live", "machine-hosts").(seeded_machine()))
      page = render("", "", [], hosts, "")

      declared =
        Regex.scan(~r/@host \$([\w-]+)/, page) |> Enum.map(fn [_, h] -> h end)

      assert declared == hosts
    end

    test "every local it declares is a signal some view writes" do
      machine = seeded_machine()
      locals = plain(fetch!("spell.live", "machine-locals").(machine))
      page = render("", "", locals, [], "")

      declared =
        Regex.scan(~r/@data inline \$([\w-]+)/, page) |> Enum.map(fn [_, l] -> l end)

      assert declared == locals
      assert "draft" in declared
    end
  end

  defp index_of(haystack, needle) do
    case :binary.match(haystack, needle) do
      {at, _} -> at
      :nomatch -> nil
    end
  end
end
