defmodule BeamLisp.Spell.PersistTest do
  @moduledoc """
  The journal is the loop's memory: accepted definitions land in
  `spell/state/journal.bl`, and a restart replays them through the SAME
  ladder — so what comes back is exactly what was accepted, and nothing that
  would not pass today.

  async: false because the state dir is process-wide config and the loop
  under test publishes through the shared verse serve.
  """
  use ExUnit.Case, async: false
  use BeamLisp.SpellCase

  alias BeamLisp.Spell.{Loop, Persist}

  @view_src """
  (defview clock
    (markup (template &clock [$m] [:div {:class "clock"} @m.text]))
    (style [".clock" {:font-size "0.75rem"}])
    (binds [".log" (st/each @messages :as @m :template &clock)]))
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "spell-persist-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:beam_lisp, :spell_state_dir)
    Application.put_env(:beam_lisp, :spell_state_dir, dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:beam_lisp, :spell_state_dir, previous),
        else: Application.delete_env(:beam_lisp, :spell_state_dir)

      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  test "a restarted loop replays the journal and the transcript", %{dir: dir} do
    {:ok, first} = Loop.start_link(name: nil, publish: false, persist: true)

    assert %{status: :ok} = Loop.run(first, @view_src, "a clock in the log")
    GenServer.call(first, {:record_user, "add a clock"})
    GenServer.call(first, {:record_model, "done — the clock is live"})
    GenServer.stop(first)

    # The journal holds the SOURCE, in the file a user can read and diff.
    journal = File.read!(Path.join(dir, "journal.bl"))
    assert journal =~ "(defview clock"
    assert journal =~ "a clock in the log"

    {:ok, second} = Loop.start_link(name: nil, publish: false, persist: true)

    assert "clock" in Loop.state(second).machine["views"],
           "the restarted loop must have the journaled view"

    messages = Loop.transcript_messages(second)

    assert Enum.any?(messages, &(&1["text"] == "add a clock")),
           "the restarted page must seed from the persisted transcript"

    assert Enum.any?(messages, &(&1["text"] =~ "clock is live"))

    GenServer.stop(second)
  end

  test "a journal entry that no longer validates is refused at boot, not trusted", %{dir: dir} do
    {:ok, first} = Loop.start_link(name: nil, publish: false, persist: true)
    assert %{status: :ok} = Loop.run(first, @view_src, "fine")
    GenServer.stop(first)

    # Hand-edit the journal into a definition the ladder refuses: an event no
    # contract handles. Boot must drop THIS entry and keep going.
    File.write!(
      Path.join(dir, "journal.bl"),
      File.read!(Path.join(dir, "journal.bl")) <>
        "\n(defview broken (markup (template &b [] [:button {:class \"b\"} \"x\"])) (binds [\".b\" (st/on :click (fire :explode))]))\n"
    )

    {:ok, second} = Loop.start_link(name: nil, publish: false, persist: true)
    state = Loop.state(second)

    assert "clock" in state.machine["views"], "the valid entry survives"
    refute "broken" in state.machine["views"], "the refused entry must not be trusted"

    GenServer.stop(second)
  end

  test "no journal means a clean seed machine", %{dir: _dir} do
    {:ok, pid} = Loop.start_link(name: nil, publish: false, persist: true)
    views = Loop.state(pid).machine["views"]
    # the DEFAULT SHELL: chat + live-state (PLAN-031)
    assert views == ["chat-view", "live-state-view"]
    GenServer.stop(pid)
  end

  test "a journal that does not READ is set aside, never booted over", %{dir: dir} do
    {:ok, first} = Loop.start_link(name: nil, publish: false, persist: true)
    assert %{status: :ok} = Loop.run(first, @view_src, "fine")
    GenServer.stop(first)

    # A torn write: half a form appended. Boot must not crash on its own state
    # file — the corrupt journal is renamed aside for manual recovery.
    journal = Path.join(dir, "journal.bl")
    File.write!(journal, File.read!(journal) <> "\n(defview torn (markup (template &t []\n")

    {:ok, second} = Loop.start_link(name: nil, publish: false, persist: true)

    # The whole journal failed to read, so the seed machine is what boots —
    # the alternative (booting over a corrupt file, or trusting a prefix)
    # both lose worse.
    assert Loop.state(second).machine["views"] == ["chat-view", "live-state-view"]
    assert File.ls!(dir) |> Enum.any?(&String.contains?(&1, "corrupt"))

    GenServer.stop(second)
  end

  test "a rationale with newlines stays ONE comment line", %{dir: dir} do
    {:ok, pid} = Loop.start_link(name: nil, publish: false, persist: true)
    assert %{status: :ok} = Loop.run(pid, @view_src, "line one\nline two")
    GenServer.stop(pid)

    journal = File.read!(Path.join(dir, "journal.bl"))
    assert journal =~ "line one line two"
    refute journal =~ "\nline two"
    # and the journal still READS — stray text would have broken parsing
    assert length(Persist.journal()) == 1
  end
end
