defmodule BeamLisp.Spell.Page do
  @moduledoc """
  The machine's page, as one EDN document.

  The assembly is entirely Lisp-side: `spell.live/machine-page-edn` merges
  every contract's seam parts, every view's planes, the host declarations, the
  page-locals and the style plane into one document and prints it once. This
  module only carries the string to a file.

  It used to render the page HERE — host decls, locals, imports and the style
  plane spliced into `.st` text around EDN parts printed by shelling out to
  verse's printer. That made Elixir a second authority on what a page
  contains (the `.st` preamble) and paid a subprocess per publish. Verse reads
  EDN directly now (FEAT-169), so the document goes to disk as-is and the
  `.st` detour — and its printer — are gone.
  """

  @doc """
  The machine's whole page as EDN text; `{:ok, document}` | `{:error, reason}`.

  `machine` is the machine VALUE — what the loop holds, not a var name.
  """
  def document(machine, opts \\ []) do
    prefix = Keyword.get(opts, :module_prefix, "SpellWeb")

    {:ok, apply(BeamLisp.Env.fetch!("spell.live", "machine-page-edn"), [machine, prefix])}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Write the machine's page to `path`; `{:ok, path}` | `{:error, reason}`."
  def emit(machine, path, opts \\ []) do
    with {:ok, doc} <- document(machine, opts) do
      File.write!(path, doc)
      {:ok, path}
    end
  end
end
