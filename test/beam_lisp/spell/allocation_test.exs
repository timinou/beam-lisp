defmodule BeamLisp.Spell.AllocationTest do
  @moduledoc """
  A contract event must cost nothing permanent.

  ## Why this is a correctness test and not a benchmark

  `BeamLisp.Compiler.eval_string/1` compiles its argument into a FRESH BEAM
  module. Modules are reclaimable; the atoms their names and literals intern
  are not — the atom table is never garbage collected, and exhausting it aborts
  the whole VM uncatchably (`BeamLisp.AtomGuard` exists for this reason alone).

  So a path that calls `eval_string` per event is not slow, it is a LEAK, and
  it sat on the two paths a user drives with their keyboard:

    * `Spell.Server.event/4` — once per keystroke-driven signal
    * `Spell.Server.info/3`  — once per STREAMED TOKEN

  Measured before the change (seed contract, 100 events): +201 modules, +204
  atoms via `eval_string`; +0 and +0 through the fn value. A 500-token answer
  therefore left roughly a thousand modules behind, permanently.

  ## Why the numbers are asserted as ZERO and not as a budget

  A budget invites drift ("+3 is fine") and cannot distinguish a leak from a
  one-off. Zero is the honest claim once the boundary is a data conversion:
  converting a map allocates no code, so nothing is ever the right number but
  none.

  The warm-up before each measurement is not padding. The first call into a
  namespace links its module and interns its names, which is a one-time cost
  that a naive measurement would report as a per-event leak.
  """

  use ExUnit.Case, async: false
  use BeamLisp.SpellCase

  alias BeamLisp.Spell.Data

  # Atoms are counted VM-globally: there is no per-caller equivalent of the
  # `BeamLisp.Eval.M*` module count, and `mix test` runs suites concurrently,
  # so a neighbour interning a handful of names lands in this number.
  #
  # The tolerance is safe because the failure it guards is not subtle:
  # `eval_string` interns roughly two atoms PER CALL, so the paths below leaked
  # ~100 and ~400 respectively when they compiled. Anything in that range is
  # two orders of magnitude clear of concurrent noise, and the MODULE count —
  # which is exact and attributable — is asserted at zero regardless.
  @atom_noise 25

  defp handle, do: fetch!("spell.server", "handle")
  defp handle_info, do: fetch!("spell.server", "handle-info")
  defp contract, do: fetch!("spell.seed", "contract-term")

  # Poll until a registered name is free. Named processes unregister
  # ASYNCHRONOUSLY, so "the process stopped" does not imply "the name is
  # available" — the gap is what leaked into sibling suites (BUG-006).
  defp wait_for_name_release(_name, 0), do: :ok

  defp wait_for_name_release(name, attempts) do
    case Process.whereis(name) do
      nil ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_name_release(name, attempts - 1)
    end
  end

  defp assigns do
    Data.to_bl(%{"messages" => [], "status" => "idle", "error" => "", "partial" => ""}, :all_strings)
  end

  describe "a page event" do
    test "50 events allocate no modules and no atoms" do
      # warm: link the namespace module and intern its names once
      handle().(contract(), "send", Data.to_bl(%{"text" => "warm"}, :all_strings), assigns())

      alloc =
        allocations(fn ->
          for i <- 1..50 do
            handle().(contract(), "send", Data.to_bl(%{"text" => "m#{i}"}, :all_strings), assigns())
          end
        end)

      assert alloc.modules == 0,
             "#{alloc.modules} modules leaked over 50 events — the event path is compiling"

      assert alloc.atoms <= @atom_noise,
             "#{alloc.atoms} atoms leaked over 50 events — the atom table is never collected"
    end
  end

  describe "a streamed token" do
    test "200 tokens allocate no modules and no atoms" do
      # The worse case, and the one that was only INFERRED when PLAN-027 was
      # written: `Spell.Server.info/3` runs once per delta. This makes it an
      # observation.
      msg = fn text -> Data.to_bl([:delta, "m1", text], :all_strings) end

      handle_info().(contract(), msg.("warm"), assigns())

      alloc =
        allocations(fn ->
          Enum.reduce(1..200, assigns(), fn i, acc ->
            handle_info().(contract(), msg.("tok#{i} "), acc)
            |> Map.get(:assigns, acc)
          end)
        end)

      assert alloc.modules == 0,
             "#{alloc.modules} modules leaked over 200 tokens — a long answer is a leak"

      assert alloc.atoms <= @atom_noise, "#{alloc.atoms} atoms leaked over 200 tokens"
    end
  end

  describe "the served path — through Spell.Server, as a LiveView drives it" do
    # The tests above call the interpreter directly and pass by construction.
    # These go through the module a LiveView actually calls, which is where the
    # leak lived: measured before the fix, ONE event cost +6 modules and +153
    # atoms, because `Spell.Server` reached beam-lisp by printing source and
    # compiling it.
    setup do
      # `PROVIDER=fake` for the duration, and this is a CORRECTNESS point rather
      # than tidiness. The seed contract's `send` handler ends in `(ask! text)`,
      # so every event here starts a provider turn: without this the suite
      # opened fifty real TLS connections to whatever `PROVIDER` names.
      #
      # It also poisoned the measurement. `httpc` interns atoms per connection
      # (measured: ~185 over 50 events, still climbing after the loop returned
      # as sockets settled), which read as a leak in spell's own event path.
      # It was not: the same fifty events through the fake transport intern
      # ZERO. Chasing that number is what found this.
      #
      # The fake transport speaks the identical message protocol, so what is
      # measured is still the whole path — minus a network this test has no
      # business touching.
      previous = System.get_env("PROVIDER")
      System.put_env("PROVIDER", "fake")

      on_exit(fn ->
        if previous, do: System.put_env("PROVIDER", previous), else: System.delete_env("PROVIDER")
      end)

      # The loop under its REGISTERED name: `maybe_ask` requires exactly
      # `Process.whereis(BeamLisp.Spell.Loop)` (there is no no-loop fallback —
      # a browser path without the loop fails loudly by design). Stopped
      # SYNCHRONOUSLY on exit: this setup runs per test, and without the stop
      # the next test's `start_link` races the previous loop's name
      # unregistration.
      {:ok, pid} = BeamLisp.Spell.Loop.start_link(out: "/tmp/spell-alloc-test", publish: false)

      # Stop the loop AND wait for its registered name to be released.
      # `GenServer.stop/1` is synchronous on the process but NOT on
      # unregistration, so returning here while the name is still held
      # made a later suite's `{:ok, _} = Loop.start_link(…)` fail with
      # `{:error, {:already_started, _}}` — a ~1-in-3 flake in
      # Spell.McpTest that passed in isolation every time (BUG-006).
      #
      # `Process.alive?` then `stop` is a TOCTOU race: the process can
      # begin shutting down between the two, and `GenServer.stop` on a
      # dying process EXITS rather than returning an error tuple — so it
      # cannot be handled with a `case`, only caught (BUG-015).
      on_exit(fn ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end

        wait_for_name_release(BeamLisp.Spell.Loop, 50)
      end)
      BeamLisp.Spell.Server.register("chat-live", "spell.seed/contract-term")
      {:ok, socket} = BeamLisp.Spell.Server.mount(%Phoenix.LiveView.Socket{}, "chat-live")
      %{socket: socket}
    end

    test "50 page events allocate nothing", %{socket: socket} do
      BeamLisp.Spell.Server.event(socket, "chat-live", "send", %{"text" => "warm"})

      alloc =
        allocations(fn ->
          for i <- 1..50 do
            BeamLisp.Spell.Server.event(socket, "chat-live", "send", %{"text" => "m#{i}"})
          end
        end)

      assert alloc.modules == 0,
             "#{alloc.modules} modules leaked over 50 events — Spell.Server is compiling per event"

      assert alloc.atoms <= @atom_noise,
             "#{alloc.atoms} atoms leaked over 50 events — the atom table is never collected, " <>
               "and exhausting it aborts the VM uncatchably"
    end

    test "200 streamed tokens allocate nothing", %{socket: socket} do
      # The worse path: `info/3` runs once per delta, so a 500-token answer
      # multiplied whatever one event cost.
      BeamLisp.Spell.Server.info(socket, "chat-live", {:delta, "m1", "warm"})

      alloc =
        allocations(fn ->
          Enum.reduce(1..200, socket, fn i, acc ->
            {:noreply, next} =
              BeamLisp.Spell.Server.info(acc, "chat-live", {:delta, "m1", "tok#{i} "})

            next
          end)
        end)

      assert alloc.modules == 0,
             "#{alloc.modules} modules leaked over 200 tokens — a long answer is a leak"

      assert alloc.atoms <= @atom_noise, "#{alloc.atoms} atoms leaked over 200 tokens"
    end

    test "a mount allocates nothing after the first", %{socket: _socket} do
      # Every browser tab mounts. A per-mount leak is a leak per VISITOR.
      BeamLisp.Spell.Server.mount(%Phoenix.LiveView.Socket{}, "chat-live")

      alloc =
        allocations(fn ->
          for _ <- 1..20, do: BeamLisp.Spell.Server.mount(%Phoenix.LiveView.Socket{}, "chat-live")
        end)

      assert alloc.modules == 0
      assert alloc.atoms <= @atom_noise
    end
  end

  describe "what the fn value path preserves" do
    test "the walk performs nothing — it RECORDS what the caller must do" do
      # The property streaming rests on, stated as the interpreter's contract
      # rather than as a pid check.
      #
      # `(ask! text)` inside a contract body does not call a provider. It
      # records a request, and the CALLER performs it — because the caller is
      # the process the answer has to come back to, and `(erlang/self)` there
      # is the LiveView's own pid. That is why a streamed token needs no second
      # transport: it arrives as an ordinary BEAM message in the mailbox of the
      # process that asked.
      #
      # If the walk ever performed the ask itself, this assertion breaks and
      # streaming breaks with it — the answer would be delivered to whichever
      # process happened to be walking.
      result =
        handle().(contract(), "send", Data.to_bl(%{"text" => "hello"}, :all_strings), assigns())

      assert Map.get(result, :ask) == "hello",
             "the body's (ask! text) was not recorded for the caller to perform"

      refute_received {:delta, _, _},
                      "the walk performed the provider call itself — a streamed answer " <>
                        "would arrive in the wrong process"
    end

    test "a walk in another process still answers that process" do
      # The same property from the other side: nothing about the walk is bound
      # to the process that LOADED the namespace. A LiveView pid walking its
      # own contract gets its own answer.
      parent = self()

      spawn(fn ->
        result =
          handle().(contract(), "send", Data.to_bl(%{"text" => "x"}, :all_strings), assigns())

        send(parent, {:walked, self(), Map.get(result, :status)})
      end)

      assert_receive {:walked, walker, "ok"}, 5_000
      refute walker == self()
    end
  end
end
