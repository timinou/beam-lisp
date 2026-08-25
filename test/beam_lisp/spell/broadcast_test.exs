defmodule BeamLisp.Spell.BroadcastTest do
  @moduledoc """
  A page that is not the one that wrote.

  ## What is actually true at the instant of a write

  Exactly one thing: the database advanced. Which rows changed, and what any
  particular page should now display, is DERIVED by the reader from its own
  question — so the writer cannot compute it.

  That is why the payload is a basis and never a board. Reel's board is
  role-scoped: `task-rows db role` answers `[doing dropped]` to a tech lead
  and `[dropped]` to a product lead for the same task. A page that rendered
  somebody else's broadcast board would show affordances computed for the
  wrong person — the exact defect commit 2107d67 removed, reintroduced
  through a mechanism where it only appears with two tabs open as two
  different leads.

  A projection is a function of (data, who is asking). A writer knows only
  its own half.

  ## Why this is two sockets

  A single-socket test cannot fail for the reason this feature exists. The
  bug IS the second page: the one that did not write, has no reply coming,
  and has no other way to learn that the world moved.
  """
  use ExUnit.Case, async: false

  alias BeamLisp.Spell.Server

  @pubsub BeamLisp.Spell.TestPubSub

  setup_all do
    BeamLisp.Spell.init!(["spell.app"])
    BeamLisp.Env.add_search_path(Path.join(File.cwd!(), "test/fixtures/bl"))
    BeamLisp.Loader.ensure_loaded("spell.intent-fixture")

    start_supervised!({Phoenix.PubSub, name: @pubsub})
    prev = Application.get_env(:beam_lisp, :spell_pubsub)
    Application.put_env(:beam_lisp, :spell_pubsub, @pubsub)
    on_exit(fn -> Application.put_env(:beam_lisp, :spell_pubsub, prev) end)

    Server.register("listen-test", "spell.intent-fixture/listening-contract")
    Server.register("silent-test", "spell.intent-fixture/silent-contract")
    :ok
  end

  # A CONNECTED socket. Phoenix mounts twice — a disconnected static render,
  # then the live one — and only the second has a process worth delivering to.
  # `Server.mount/2` is called directly here rather than through
  # `Phoenix.LiveViewTest`, the way every other socket test in this suite does
  # it, so the connection flag is set the way the runtime sets it.
  defp connected_socket do
    %Phoenix.LiveView.Socket{
      transport_pid: self(),
      private: %{connect_info: %{}}
    }
  end

  defp disconnected_socket, do: %Phoenix.LiveView.Socket{}

  describe "a page joins the topic its contract names" do
    test "a connected mount subscribes" do
      {:ok, _socket} = Server.mount(connected_socket(), ["listen-test"])

      # Proof by delivery: broadcast on the topic and see it arrive in THIS
      # process, which is the one that mounted. Asserting on a subscriber list
      # would test Phoenix's bookkeeping; asserting on arrival tests the thing
      # the feature is for.
      Phoenix.PubSub.broadcast(@pubsub, "things", {:"spell/changed", 42})

      assert_receive {:"spell/changed", 42}, 500
    end

    test "a DISCONNECTED mount does not subscribe" do
      # Phoenix calls mount/3 twice per live navigation. The first pass runs
      # in a request process that exits immediately afterwards — subscribing
      # there registers a dead pid on the topic and, worse, doubles every
      # delivery for as long as it lives.
      {:ok, _socket} = Server.mount(disconnected_socket(), ["listen-test"])

      Phoenix.PubSub.broadcast(@pubsub, "things", {:"spell/changed", 7})

      refute_receive {:"spell/changed", 7}, 200
    end

    test "a contract with no topic subscribes to nothing" do
      # The regression guard. Every contract written before topics existed
      # must mount exactly as it did, so the DEFAULT has to be silence rather
      # than a name derived from the contract.
      {:ok, _socket} = Server.mount(connected_socket(), ["silent-test"])

      Phoenix.PubSub.broadcast(@pubsub, "things", {:"spell/changed", 9})

      refute_receive {:"spell/changed", 9}, 200
    end
  end

  describe "what arrives reaches the contract's own handler" do
    test "a change message routes through on-info" do
      {:ok, socket} = Server.mount(connected_socket(), ["listen-test"])

      # `handle_info` is generated per `on-info` pattern and already existed;
      # what was missing was anything ever ARRIVING at it. This asserts the
      # whole path: the message reaches the head, the head walks the
      # contract's body, and the body's assigns land on the socket.
      {:noreply, socket} =
        Server.info(socket, ["listen-test"], {:"spell/changed", 314})

      assert socket.assigns.seen == 314,
             "the contract's own on-info body must run, and its assigns must land"
    end
  end
end
