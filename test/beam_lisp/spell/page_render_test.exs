defmodule BeamLisp.Spell.PageRenderTest do
  @moduledoc """
  The machine's page as a complete EDN document.

  `Page.document(machine)` calls into spell.live/machine-page-edn, which merges
  the seam (contract + host-live + data-inline forms), the view parts (markup,
  style, binds), and assembles them with their stdlib imports. This suite
  verifies that assembly: the declarations appear in the right order, with the
  right names, and the imports cover what the forms need.

  The contract's naming rule has ONE implementation now: `spell.contract/module-name`.
  This suite exercises it transitively through the host-live form, rather than
  testing both the form and a duplicate Elixir-side rule that no longer exists.
  """

  use ExUnit.Case, async: false
  use BeamLisp.SpellCase

  alias BeamLisp.Spell.Page

  describe "the complete page document" do
    test "contains :st/imports with all six stdlib paths" do
      {:ok, doc} = Page.document(seeded_machine())

      for import <- ~w(data-kind each on host handle) do
        assert doc =~ "stdlib/macros/#{import}"
      end

      assert doc =~ "stdlib/enum/dispatch"
    end

    test "contains a host-live form naming the module correctly" do
      {:ok, doc} = Page.document(seeded_machine())
      assert doc =~ "(host-live :module"
      assert doc =~ "$chat-live"
      assert doc =~ "SpellWeb.ChatLive"
    end

    test "contains a data-inline form for page-locals" do
      {:ok, doc} = Page.document(seeded_machine())
      assert doc =~ "(data-inline :name $draft"
    end

    test "contains a :st/css member when seed has styles" do
      {:ok, doc} = Page.document(seeded_machine())
      assert doc =~ ":st/css"
      assert doc =~ ".chat"
    end

    test "host-live and data-inline forms appear before any seam/view forms" do
      {:ok, doc} = Page.document(seeded_machine())

      host_idx = index_of(doc, "(host-live :module")
      data_idx = index_of(doc, "(data-inline :name $draft")
      first_use_idx = Enum.min([index_of(doc, "(data-subscribe"), index_of(doc, "(template"), index_of(doc, "(sel ")])

      assert is_integer(host_idx), "host-live form not found"
      assert is_integer(data_idx), "data-inline form not found"
      assert is_integer(first_use_idx), "no seam/view use form found"
      assert host_idx < first_use_idx, "host-live must be declared before use"
      assert data_idx < first_use_idx, "data-inline must be declared before use"
    end

    test "module_prefix option is honored" do
      {:ok, doc} = Page.document(seeded_machine(), module_prefix: "OtherWeb")
      assert doc =~ "OtherWeb.ChatLive"
      refute doc =~ "SpellWeb.ChatLive"
    end

    test "every host declared is a contract the machine registered" do
      machine = seeded_machine()
      hosts = plain(fetch!("spell.live", "machine-hosts").(machine))
      {:ok, doc} = Page.document(machine)

      for host <- hosts do
        assert doc =~ "$#{host}"
      end
    end

    test "every local declared is a signal some view writes" do
      machine = seeded_machine()
      locals = plain(fetch!("spell.live", "machine-locals").(machine))
      {:ok, doc} = Page.document(machine)

      for local <- locals do
        assert doc =~ "$#{local}"
      end

      assert "draft" in locals
    end
  end

  defp index_of(haystack, needle) do
    case :binary.match(haystack, needle) do
      {at, _} -> at
      :nomatch -> nil
    end
  end
end
