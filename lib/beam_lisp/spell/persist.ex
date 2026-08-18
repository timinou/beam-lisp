defmodule BeamLisp.Spell.Persist do
  @moduledoc """
  The loop's memory across restarts: a JOURNAL, not a snapshot.

  `spell/state/journal.bl` holds every accepted definition's SOURCE, one form
  per entry, in acceptance order. Boot replays the journal through the same
  ladder a live tool call walks — so a hand-edited or bit-rotted entry is
  REFUSED at replay (loudly, in the log) rather than silently trusted, and
  there is exactly one definition of "valid machine" in the system.

  The alternative — serializing the machine TERM — was rejected because it
  splits truth in two: the journal path checks at boot, the snapshot path
  would have to trust. A machine that can be edited into existence behind the
  ladder's back is the bug the ladder exists to prevent.

  `spell/state/transcript.json` is the conversation snapshot, rewritten on
  each recorded turn. It is display state, not authority: a corrupt transcript
  costs the page its history until the next turn, so it is dropped rather
  than refused.

  The transcript is written tmp-then-rename; the JOURNAL is appended (an
  append of a complete entry is already crash-safe at entry granularity — a
  torn tail fails to READ, which `journal/0` sets aside rather than trusting
  or booting over).

  ONE writer: the journal has no locking, because the loop is one process by
  design and two loops pointing at the same state dir is a deployment bug,
  not a scenario to engineer for.
  """


  @default_dir "spell/state"

  def dir do
    Application.get_env(:beam_lisp, :spell_state_dir, @default_dir)
  end

  def journal_path, do: Path.join(dir(), "journal.bl")
  def vars_path, do: Path.join([dir(), "vars", "spell.vars.bl"])
  def transcript_path, do: Path.join(dir(), "transcript.json")

  @doc """
  Append one accepted definition's source. Entries are separated by a blank
  line and a comment marker so the journal stays human-diffable — it is a
  project-local artifact the user is expected to read and, if needed, edit.
  """
  def append_definition(source, rationale), do: append_entry(journal_path(), source, rationale)

  @doc """
  Append one accepted CODE definition (`defn`/`def`) to the vars journal —
  `vars/spell.vars.bl`, replayed BEFORE the definitions journal at boot so a
  view can reach for a fn the same session already taught the image.
  """
  def append_var(source, rationale), do: append_entry(vars_path(), source, rationale)

  defp append_entry(path, source, rationale) do
    File.mkdir_p!(Path.dirname(path))

    # One physical line: a rationale containing a newline would break out of
    # the comment and land as stray top-level text in the journal — readable
    # as forms, refused at replay, and confusing to a human diffing the file.
    rationale = String.replace(rationale, ~r/\s+/, " ") |> String.trim()

    entry =
      "\n;; accepted #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}" <>
        if(rationale == "", do: "", else: " — " <> rationale) <> "\n" <> String.trim(source) <> "\n"

    File.write!(path, entry, [:append])
    :ok
  end

  @doc "The journal's entries, oldest first. `[]` when there is no journal."
  def journal, do: entries(journal_path())

  @doc "The vars journal's entries, oldest first. `[]` when absent."
  def vars, do: entries(vars_path())

  defp entries(path) do
    case File.read(path) do
      {:ok, text} -> parse_journal(text, path)
      {:error, :enoent} -> []
    end
  end

  # The journal is a beam-lisp FILE: read every top-level form as DATA with
  # the reader (never evaluated — the same boundary `run` keeps), and print
  # each back to source for the replay call. `read_all_data` — not
  # `Reader.read_all` — because the reader's own return is the tagged
  # `{:list, …}` form representation, which is compiler input, not a value:
  # printing THAT would journal `{:list, [{:symbol, …}]}` garbage.
  #
  # A journal that does not READ (truncated write, hand-edit gone wrong) must
  # not strand the boot: set it aside for manual recovery and start from the
  # seed. Refusing to boot over a state file would make persistence itself
  # the most dangerous file in the project.
  defp parse_journal(text, path) do
    text
    |> BeamLisp.Compiler.read_all_data()
    |> Enum.map(&pr_str/1)
  rescue
    e in BeamLisp.Reader.SyntaxError ->
      aside = path <> ".corrupt-#{System.unique_integer([:positive])}"
      File.rename(path, aside)

      require Logger

      Logger.warning(
        "spell.persist: the journal does not read (#{Exception.message(e)}); " <>
          "set aside at #{aside} and booting from the seed"
      )

      []
  end

  # A read form back to source. `BeamLisp.RT.print_str` prints runtime values
  # readably for exactly this purpose (strings quoted, keywords literal).
  defp pr_str(form), do: BeamLisp.RT.print_str(form)

  @doc "Replace the transcript snapshot. Display state; best-effort."
  def write_transcript(messages) do
    File.mkdir_p!(dir())
    tmp = transcript_path() <> ".tmp"
    File.write!(tmp, JSON.encode!(messages))
    File.rename!(tmp, transcript_path())
    :ok
  end

  @doc "The last transcript snapshot, or [] when absent or unreadable."
  def read_transcript do
    with {:ok, text} <- File.read(transcript_path()),
         {:ok, messages} when is_list(messages) <- JSON.decode(text) do
      messages
    else
      _ -> []
    end
  end
end
