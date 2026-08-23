defmodule BeamLisp.Spell.IntentTest do
  @moduledoc """
  `(do! :op payload)` — the seam an APPLICATION acts through.

  The walker (`spell.server`) is a closed vocabulary: special forms plus a
  whitelist of pure functions, and an unknown head is refused by name. That is
  the property that makes a model-proposed contract safe to execute, and it is
  also a wall for a program whose handlers must reach a database. `do!` is the
  door, built to the shape `ask!` already proved: the body RECORDS what it
  wants done, and the layer that owns the authority does it.

  These tests assert the SOCKET half — that a performer actually runs, in the
  right process, that its assigns beat the handler's own, and that an
  unregistered op fails loudly. The walker half (what `do!` records, in what
  order, computed from what) lives in `test/bl/spell/server_test.bl`, where it
  needs no socket at all.

  The contracts under test are beam-lisp source
  (`test/bl/spell/intent_fixture.bl`) rather than terms assembled here from
  Elixir data: a hand-assembled term is a guess about how the reader spells a
  symbol and a map key, and when the guess is wrong the failure is about the
  fixture instead of about the feature. (Tried it; it was.)
  """
  use ExUnit.Case, async: false

  alias BeamLisp.Spell.Server

  @performers {BeamLisp.Spell.Server, :performers}

  setup_all do
    BeamLisp.Spell.init!(["spell.app"])
    # A FIXTURE, under test/fixtures/, because it is a compiler input rather
    # than a suite: `mix beam_lisp.test` with no argument globs `test/**/*.bl`
    # and excludes exactly that directory, so a contract living anywhere else
    # under test/ would be run as if it were a test file and report zero
    # assertions forever.
    BeamLisp.Env.add_search_path(Path.join(File.cwd!(), "test/fixtures/bl"))
    BeamLisp.Loader.ensure_loaded("spell.intent-fixture")

    # The seed contract, registered by name, because the "nothing else changed"
    # cases drive it. Without a running Loop there is no machine to fall back
    # to, so an unregistered name raises rather than resolving — which is the
    # registry working, and is why this line exists.
    Server.register("chat-live", "spell.seed/contract-term")
    :ok
  end

  setup do
    on_exit(fn -> :persistent_term.put(@performers, %{}) end)
    :persistent_term.put(@performers, %{})
    use_contract("create-contract")
    :ok
  end

  describe "a performer runs" do
    test "the intent reaches it, with its op and payload" do
      me = self()

      Server.register_performer("create-task", fn op, payload ->
        send(me, {:performed, op, payload})
        nil
      end)

      {:reply, reply, _socket} = Server.event(socket(), "intent-test", "create", "Ship it")

      assert reply.tag == "ok"
      assert reply.reply == "created"
      assert_receive {:performed, "create-task", payload}
      assert payload["title"] == "Ship it"
    end

    test "it runs in the LiveView's own process, so async work can answer home" do
      me = self()

      Server.register_performer("create-task", fn _op, _payload ->
        send(me, {:ran_in, self()})
        nil
      end)

      Server.event(socket(), "intent-test", "create", "x")

      # `ask!` starts a provider turn whose tokens must come back to the pid
      # that owns the socket, and `Spell.Server`'s own docs lean on the walk
      # running in the caller for exactly that reason. A performer that
      # borrowed a Task would break the property for anything IT starts, so the
      # process identity is asserted rather than assumed.
      assert_receive {:ran_in, pid}
      assert pid == self()
    end

    test "the assigns it answers with reach the socket" do
      Server.register_performer("create-task", fn _op, _payload ->
        %{"status" => "from-performer"}
      end)

      {:reply, _reply, socket} = Server.event(socket(), "intent-test", "create", "x")
      assert socket.assigns.status == "from-performer"
    end

    test "a performer answering nil leaves the page's state alone" do
      Server.register_performer("create-task", fn _op, _payload -> nil end)

      {:reply, _reply, socket} =
        Server.event(socket(%{status: "untouched"}), "intent-test", "create", "x")

      assert socket.assigns.status == "untouched"
    end

    test "a refused event never reaches the performer" do
      me = self()
      Server.register_performer("create-task", fn _o, _p -> send(me, :ran) && nil end)

      {:reply, reply, _socket} = Server.event(socket(), "intent-test", "create", "")

      # The handler's own guard runs BEFORE the intent is recorded, so a blank
      # title never becomes a write. A validation only the performer enforced
      # would be a validation the page cannot explain.
      assert reply.tag == "err"
      refute_receive :ran, 100
    end

    test "a beam-lisp fn can be registered by name, so the domain stays in .bl" do
      # The registration path an application actually takes, and the whole
      # reason `do!` is worth having: the walker stays closed, this module
      # learns nothing about the domain, and the code that ACTS is beam-lisp.
      Server.register_performer("create-task", "spell.intent-fixture/perform-probe")

      {:reply, _reply, socket} = Server.event(socket(), "intent-test", "create", "Ship")
      assert socket.assigns.status == "performed:Ship"
    end
  end

  describe "ordering" do
    test "the performer's assigns beat the handler's own" do
      # THE ordering that matters. A body that creates a task and then wants the
      # board to show it gets the fresh board from the performer — read back
      # from the database AFTER the write. If the walk's assigns landed last,
      # the handler's pre-write copy would overwrite the database's current one
      # and a browser would show a list that did not change, which is the
      # failure that makes people click twice.
      use_contract("stale-contract")

      Server.register_performer("create-task", fn _op, _payload ->
        %{"status" => "fresh-from-the-database"}
      end)

      {:reply, _reply, socket} = Server.event(socket(), "intent-test", "create", "x")
      assert socket.assigns.status == "fresh-from-the-database"
    end

    test "two intents in one body run in the order written" do
      use_contract("two-contract")
      me = self()

      Server.register_performer("first", fn _o, _p -> send(me, {:ran, :first}) && nil end)
      Server.register_performer("second", fn _o, _p -> send(me, {:ran, :second}) && nil end)

      Server.event(socket(), "intent-test", "create", "x")

      # ONE pattern, twice, then compare — not `assert_receive :first` followed
      # by `assert_receive :second`.
      #
      # That spelling cannot fail, which a reviewer caught: `assert_receive` is
      # a SELECTIVE receive, so with the intents performed backwards it scans
      # past the queued `:second`, matches `:first`, and the next assertion
      # then matches what is left. Both pass either way, and the load-bearing
      # ordering this test exists for would be unprotected.
      #
      # Matching `{:ran, _}` twice takes the messages in ARRIVAL order, which
      # is the thing under test.
      assert_receive {:ran, one}
      assert_receive {:ran, two}
      assert [one, two] == [:first, :second]
    end
  end

  describe "the refusal" do
    test "an unregistered op fails by name, listing what IS registered" do
      Server.register_performer("something-else", fn _o, _p -> nil end)

      # LOUD. The walker cannot know what an application performs and does not
      # try; the authority to perform lives in the host, so the refusal does
      # too. Silence here would be a click that does nothing.
      error =
        assert_raise ArgumentError, fn ->
          Server.event(socket(), "intent-test", "create", "x")
        end

      assert error.message =~ ~s(no performer for intent "create-task")
      assert error.message =~ "something-else"
    end

    test "a performer cannot be reached from a handler body" do
      # The property `do!` must not cost. There is no interop head in the walker
      # at all, so a body naming an Elixir module is refused by the same rule
      # that refuses `(System/halt)`.
      use_contract("evil-contract")
      Server.register_performer("create-task", fn _o, _p -> nil end)

      assert_raise BeamLisp.ExInfo, fn ->
        Server.event(socket(), "intent-test", "evil", nil)
      end
    end
  end

  describe "the atom-table boundary" do
    test "a performer answering an UNDECLARED assign is refused by name" do
      # The hole a reviewer found, closed. `assign_all/2` interns every key it
      # is given — safe for the contract's own declared names (a handful, fixed
      # at definition time), unsafe for anything a performer derived from wire
      # data. This performer echoes the payload's title as a KEY, which is
      # exactly the shape that would intern one permanent atom per request; a
      # full atom table aborts the VM uncatchably.
      Server.register_performer("create-task", "spell.intent-fixture/perform-undeclared")

      error =
        assert_raise ArgumentError, fn ->
          Server.event(socket(), "intent-test", "create", "attacker-chosen-key")
        end

      assert error.message =~ "undeclared assign"
      assert error.message =~ "attacker-chosen-key"
      # And it names the vocabulary, because the ordinary cause is a typo.
      assert error.message =~ "status"
    end

    test "a DECLARED assign still passes" do
      # The bound must not cost the feature: `status` is declared by the
      # fixture contract, so the performer's answer lands.
      Server.register_performer("create-task", "spell.intent-fixture/perform-probe")
      {:reply, _reply, socket} = Server.event(socket(), "intent-test", "create", "Ship")
      assert socket.assigns.status == "performed:Ship"
    end

    test "a performer answering a non-map is refused" do
      Server.register_performer("create-task", "spell.intent-fixture/perform-nonsense")

      error =
        assert_raise ArgumentError, fn ->
          Server.event(socket(), "intent-test", "create", "x")
        end

      assert error.message =~ "must answer a map of assigns or nil"
    end
  end

  describe "a mount event may read, not write" do
    test "a mount event that records an intent is refused, naming the op" do
      # Phoenix mounts TWICE for a live navigation — disconnected, then
      # connected — so an intent in a mount event is a write per page load,
      # performed twice, half of it in a request process that exits
      # immediately afterwards. That is not a behaviour any contract author
      # would choose, and it would show up only in production.
      use_contract("mount-writes-contract")
      Server.register_performer("create-task", fn _o, _p -> nil end)

      error =
        assert_raise ArgumentError, fn ->
          Server.mount(socket(), ["intent-test"])
        end

      assert error.message =~ "mount event"
      assert error.message =~ "create-task"
    end

    test "a mount event that only computes state still works" do
      # The refusal must not take the legitimate affordance with it: computing
      # the state a page opens with is what a mount event is FOR, and the
      # live-state contract's `:refresh` does exactly this.
      use_contract("mount-reads-contract")
      {:ok, socket} = Server.mount(socket(), ["intent-test"])
      assert socket.assigns.status == "mounted"
    end
  end

  describe "nothing else changed" do
    test "the seed contract still runs with no performer registered at all" do
      # The existing path takes `intents: []` and must not notice the feature
      # exists. The host tolerates a missing key and a nil alike, so this does
      # not guard a crash — it guards the SHAPE: every result map carries the
      # key, so a caller reading `result["intents"]` never has to ask which of
      # three spellings of "none" it got.
      {:reply, reply, socket} =
        Server.event(socket(%{messages: [], status: "idle"}), "chat-live", "send", "")

      assert reply.tag == "err"
      assert socket.assigns.messages == []
    end

    test "an on-info clause with no intents is unaffected" do
      {:noreply, socket} =
        Server.info(
          socket(%{partial: "", status: "thinking", messages: []}),
          "chat-live",
          {:delta, "m1", "hel"}
        )

      assert socket.assigns.partial == "hel"
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp socket(assigns \\ %{}) do
    Enum.reduce(assigns, %Phoenix.LiveView.Socket{}, fn {k, v}, acc ->
      Phoenix.Component.assign(acc, k, v)
    end)
  end

  # Point the contract name at one of the fixture terms. A resolver, not a
  # value, because that is what `register/2` takes and what the machine's own
  # late binding relies on.
  defp use_contract(var) do
    Server.register("intent-test", fn -> BeamLisp.Env.fetch!("spell.intent-fixture", var) end)
  end
end
