defmodule BeamLisp.Spell.ServedLoopTest do
  @moduledoc """
  A browser event reaching `define` — the join this whole plan is about.

  ## What was wrong

  Two loops existed and only one had the tool:

      Spell.Live          offers `define`, walks the 4-rung ladder,
                          re-emits the page — reachable only from a script
      Spell.Server        what a LiveView calls; `(ask! text)` went straight
                          to `stream-async` with `(from-env)`, a cfg carrying
                          NO `:tools`

  `spell.provider/request-body` omits the `tools` array when `:tools` is empty,
  so the model answering a BROWSER was structurally incapable of proposing
  anything. Every test passed, because the loop's tests drove `Spell.Live`
  directly and the server's tests only checked that tokens arrived.

  A user typing "add a clock" into the page got a paragraph ABOUT clocks. The
  demo proved the machine could grow itself; nothing a human could see could.

  ## What this suite pins

  The whole path, offline, from a REAL recorded turn:

      Server.event("send")  →  contract's `(ask! text)`
                            →  Spell.Live.ask_async
                            →  the provider, WITH the define tool
                            →  a streamed tool call, reassembled
                            →  the 4-rung ladder (verse included)
                            →  the machine grows
                            →  `[:defined …]` back to the LiveView
                            →  the contract's on-info clause renders it

  `test/cassettes/stream-tool-call.edn` is a live glm-5.3 turn: 163 SSE frames
  carrying one `define` call. Replaying it means this suite exercises the same
  code a live turn runs, minus the socket.
  """

  use ExUnit.Case, async: false
  use BeamLisp.SpellCase

  alias BeamLisp.Spell.{Live, Server}

  @out Path.join(System.tmp_dir!(), "spell-served-loop")

  setup_all do
    File.rm_rf(@out)
    File.mkdir_p!(@out)

    # The loop under its REGISTERED name, because that is how `Spell.Server`
    # finds it — `Process.whereis(BeamLisp.Spell.Live)`. Naming it anything
    # else here would test a wiring nobody uses.
    {:ok, pid} = Live.start_link(out: @out, publish: false)
    Server.register("chat-live", "spell.seed/contract-term")

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(@out)
    end)

    :ok
  end

  # A socket whose assigns are the contract's DECLARED initials, with no
  # restored conversation.
  #
  # `Server.mount/2` deliberately seeds from the loop's transcript, so a
  # reloaded browser finds the conversation it was having. That is correct in
  # production and wrong for a test asserting what ONE turn produces: every
  # earlier test's turns would arrive with it, and the assertions would drift
  # as the suite grew.
  #
  # So a test that examines a single turn starts from the declared seed, and
  # the test that examines RESTORATION mounts through `Server.mount/2` and says
  # so. Two different questions, two different starting points.
  defp socket do
    {:ok, socket} = Server.mount(%Phoenix.LiveView.Socket{}, "chat-live")
    Phoenix.Component.assign(socket, :messages, [])
  end

  # Drain the LiveView's mailbox into a list, feeding each message through the
  # contract exactly as `SpellWeb.ChatLive.handle_info/2` does. What comes back
  # is the assigns a browser would have, which is the only thing worth
  # asserting: a message the contract cannot decode changes nothing, and that
  # must be visible as "nothing rendered", not as a passing test.
  defp drain(socket, timeout \\ 30_000) do
    receive do
      {:done, _id} = message ->
        {:noreply, socket} = Server.info(socket, "chat-live", message)
        socket

      message when is_tuple(message) ->
        {:noreply, socket} = Server.info(socket, "chat-live", message)
        drain(socket, timeout)
    after
      timeout -> flunk("the turn never ended — no [:done …] arrived within #{timeout}ms")
    end
  end

  describe "the tool actually reaches the model" do
    test "the cfg a served turn runs with declares define" do
      # The defect, asserted at its narrowest point. `turn_cfg/0` is now the ONE
      # definition of what the model may do, and `Server.maybe_ask/3` gets it by
      # asking the loop rather than building its own.
      cfg = Live.turn_cfg()
      tools = BeamLisp.Vector.to_list(Map.get(cfg, :tools))

      assert length(tools) == 1
      assert Map.get(hd(tools), :name) == "define"
    end

    test "a cfg with tools actually emits a tools array in the request" do
      # One layer down, because `:tools` being present in the cfg is not the
      # same as it reaching the wire: `request-body` omits the array when the
      # list is empty, and an empty list is exactly what the served path had.
      body =
        fetch!("spell.provider", "request-body").(
          Live.turn_cfg(),
          BeamLisp.Spell.Data.to_bl([%{role: "user", content: "hi"}], :as_written),
          false
        )

      assert body =~ ~s|"tools":[|
      assert body =~ ~s|"name":"define"|
    end
  end

  describe "a page event grows the machine" do
    @tag :verse
    test "send → a recorded tool call → the ladder → a bigger machine" do
      # The end-to-end claim, offline.
      #
      # ORDER-INDEPENDENT, deliberately.
      #
      # The obvious form — snapshot `views`, assert it grew — depends on no
      # sibling test having defined `clock` first, and `Server.maybe_ask/3`
      # finds the loop by its REGISTERED name, so a private loop cannot be
      # substituted. A guard caught the collision once; a growth test that
      # depends on execution order will lie eventually.
      #
      # So the claim is made two ways that do not care about order:
      #   1. the view IS in the machine afterwards
      #   2. the page received a ✓ VERDICT for it during this turn
      # (2) is what proves the event reached `define` NOW rather than earlier —
      # a second definition of an existing view is a legitimate no-op, but it
      # still walks the ladder and still answers.
      socket = with_cassette("stream-tool-call", fn -> ask_and_drain("add a clock") end)

      assert "clock" in Live.state().machine["views"],
             "a browser event did not reach `define` — the two loops are still separate"

      # And the page must SAY so: a machine that grew silently is a page the
      # user watches not change.
      last = socket.assigns.messages |> List.last()
      assert last["role"] == "model"
      assert last["text"] =~ "defined view"
      assert socket.assigns.status == "idle"
    end

    @tag :verse
    test "a REFUSED proposal reports the rung and leaves the machine alone" do
      # The negative half. Without it, a `define` that accepted everything would
      # pass the test above.
      #
      # The fixture is the recorded tool call with its bind selector rewritten
      # to one nothing renders — so it fails at rung 4, exactly as a model's
      # honest mistake would.
      before = Live.state().machine

      socket =
        with_cassette("stream-tool-call-unmounted", fn -> ask_and_drain("add a floating clock") end)

      assert Live.state().machine == before,
             "a refused definition changed the machine"

      texts = Enum.map(socket.assigns.messages, & &1["text"])

      # The reason appears in the transcript, not necessarily LAST: a refusal
      # is retried (see the retry test below), so the final word is the
      # exhaustion notice and the diagnostics precede it. Asserting on the tail
      # would pass only while the browser path had no retry.
      assert Enum.any?(texts, &(&1 =~ "refused at the ghosts rung")),
             "the user was not told WHY: #{inspect(texts)}"

      assert socket.assigns.status == "idle",
             "the thinking indicator never stopped after a refusal"
    end
  end

  describe "a refused proposal is retried, as it is from a script" do
    @tag :verse
    test "the model gets @max_attempts tries, then the user is told it ran out" do
      # `turn/3` — the synchronous path a script drives — has always fed a
      # refusal back to the model with the failing rung and the diagnostic, up
      # to three times. The browser path did not: a rejected proposal simply
      # ended the turn, so a user watching the page got ONE attempt while a
      # script got three.
      #
      # Two behaviours behind one capability is what PLAN-027 exists to remove.
      # W3 joined the code and did not join this.
      socket = with_cassette("stream-tool-call-unmounted", fn -> ask_and_drain("add a floating clock") end)

      texts = Enum.map(socket.assigns.messages, & &1["text"])
      refusals = Enum.count(texts, &(&1 =~ "refused at the ghosts rung"))

      assert refusals == 3,
             "the model got #{refusals} attempt(s), not 3 — the browser path is not retrying"

      assert List.last(texts) =~ "no definition accepted after 3 attempts",
             "the budget ran out silently: #{inspect(List.last(texts))}"

      assert socket.assigns.status == "idle"
    end
  end

  describe "the conversation survives the reload it causes" do
    @tag :verse
    test "a remounted page seeds from the loop's transcript" do
      # The page reloads itself when the machine grows — that is the point —
      # and a reload REMOUNTS the LiveView, which seeds from the contract's
      # declared initials: an empty transcript.
      #
      # So asking for a clock worked, the page rebuilt, and the message that
      # asked for it vanished at the exact moment the clock appeared. Observed
      # in a browser; it reads as the send having failed.
      with_cassette("stream-tool-call", fn -> ask_and_drain("add a clock please") end)

      # A FRESH mount, as a reloaded browser performs.
      {:ok, remounted} = Server.mount(%Phoenix.LiveView.Socket{}, "chat-live")
      texts = Enum.map(remounted.assigns.messages, & &1["text"])

      assert Enum.any?(texts, &(&1 =~ "add a clock please")),
             "the user's own message did not survive the reload: #{inspect(texts)}"

      assert Enum.any?(texts, &(&1 =~ "defined view")),
             "the verdict did not survive the reload: #{inspect(texts)}"

      # NOT asserted here: that the machine grew. A sibling test may have
      # already defined `clock`, and the second definition of a view the
      # machine holds is legitimately a no-op. What this test is about is the
      # TRANSCRIPT surviving a remount, and `views` would only make it
      # order-dependent. The growth claim lives in its own test above.
      assert length(texts) >= 2
    end
  end

  describe "every verdict reaches the user" do
    test "a refusal and an acceptance in one turn both land in the transcript" do
      # A turn can carry several `define` calls. When a refusal was sent as a
      # `[:delta …]` it accumulated into `@partial`, and the next acceptance's
      # `[:defined …]` CLEARED that buffer — so the user saw the success and
      # never learned why the other proposal was rejected.
      #
      # Driven as raw messages rather than through a provider, because the
      # shape being tested is the message protocol itself: what the contract
      # does with two verdicts in one turn.
      socket = socket()

      messages = [
        {:defined, "m1", "✗ the definition was refused at the ghosts rung: .nowhere renders nothing"},
        {:defined, "m1", "✓ defined view \"clock\" — a timestamped clock face"},
        {:done, "m1"}
      ]

      socket =
        Enum.reduce(messages, socket, fn message, acc ->
          {:noreply, next} = Server.info(acc, "chat-live", message)
          next
        end)

      texts = Enum.map(socket.assigns.messages, & &1["text"])

      assert length(texts) == 2,
             "a verdict was lost: #{inspect(texts)}"

      assert Enum.any?(texts, &(&1 =~ "refused at the ghosts rung")),
             "the refusal never reached the user"

      assert Enum.any?(texts, &(&1 =~ "defined view")),
             "the acceptance never reached the user"
    end

    test "a turn that only streams prose still commits it on done" do
      # The mirror of the bug above: guarding `done` on `@partial` must not
      # drop a real answer.
      socket = socket()

      socket =
        Enum.reduce(
          [{:delta, "m1", "hello "}, {:delta, "m1", "world"}, {:done, "m1"}],
          socket,
          fn message, acc ->
            {:noreply, next} = Server.info(acc, "chat-live", message)
            next
          end
        )

      assert List.last(socket.assigns.messages)["text"] == "hello world"
      assert socket.assigns.partial == ""
    end
  end

  describe "an ordinary answer still streams" do
    test "content arrives as deltas and joins the transcript" do
      # The tool path must not have replaced the prose path. A model that
      # answers a question is the common case, and it must still stream token
      # by token rather than arriving in one frame.
      socket = with_cassette("stream-content", fn -> ask_and_drain("what is a contract?") end)

      last = socket.assigns.messages |> List.last()
      assert last["role"] == "model"
      assert String.length(last["text"]) > 20
      assert socket.assigns.partial == "", "the streaming buffer outlived the turn"
      assert socket.assigns.status == "idle"
    end
  end

  # ── driving ────────────────────────────────────────────────────────────────

  # Fire `send` the way the browser does, then decode every message the turn
  # sends back through the contract.
  defp ask_and_drain(text) do
    socket = socket()
    {:reply, %{tag: "ok"}, socket} = Server.event(socket, "chat-live", "send", %{"text" => text})

    assert socket.assigns.status == "thinking",
           "the page did not enter its thinking state, so the user sees nothing happen"

    drain(socket)
  end

  # Point the loop's provider at a cassette for the duration.
  #
  # Through the environment because `turn_cfg/0` reads `from-env`, and the
  # alternative — threading a transport through `ask_async` — would put a test
  # affordance in the production signature. `SPELL_TRANSPORT` is read in one
  # place (`spell.provider/from-env`) and means exactly "where do the bytes come
  # from".
  defp with_cassette(name, fun) do
    previous = System.get_env("SPELL_CASSETTE")
    System.put_env("SPELL_CASSETTE", name)

    try do
      fun.()
    after
      if previous, do: System.put_env("SPELL_CASSETTE", previous), else: System.delete_env("SPELL_CASSETTE")
    end
  end
end
