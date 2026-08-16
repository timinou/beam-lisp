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

  defp socket do
    {:ok, socket} = Server.mount(%Phoenix.LiveView.Socket{}, "chat-live")
    socket
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
      before = Live.state().machine["views"]
      refute "clock" in before, "the fixture view already exists — the test proves nothing"

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

      last = socket.assigns.messages |> List.last()

      assert last["text"] =~ "refused at the ghosts rung",
             "the user was not told WHY: #{inspect(last["text"])}"

      assert socket.assigns.status == "idle",
             "the thinking indicator never stopped after a refusal"
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
