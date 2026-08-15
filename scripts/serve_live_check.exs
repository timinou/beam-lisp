# scripts/serve_live_check.exs — the served loop, asserted, without a browser.
#
#   mix run scripts/serve_live_check.exs
#
# Drives the SAME path a browser drives — `SpellWeb.ChatLive`'s generated
# callbacks, `spell.server`'s walk of the contract body, the provider's message
# protocol — and asserts what comes back. What it does NOT cover is rendering;
# that needs a browser and is done through `scripts/serve_live.exs` by hand.
#
# It runs offline (`PROVIDER=fake`, unless one is already set) because a check
# that only passes while a paid API answers is not a check. Both configured
# providers were walled on the day this was written.

defmodule ServeLiveCheck do
  alias BeamLisp.{Compiler, Spell}

  def run do
    # FORCED, not defaulted. An ambient `PROVIDER=kimi` (exported by a shell that
    # sourced .env) made this script issue a real, paid, network call and then
    # fail with "no provider message arrived" when the account's quota was gone
    # — a check that reaches the network depending on the caller's environment
    # is exactly the flakiness it exists to prevent. `SPELL_CHECK_PROVIDER`
    # overrides for someone deliberately checking a live provider.
    System.put_env("PROVIDER", System.get_env("SPELL_CHECK_PROVIDER") || "fake")

    Spell.init!(["spell.app", "spell.live"])

    Compiler.eval_string("""
    (def live-machine
      (spell.live/seeded (spell.machine/empty-machine)
                         spell.seed/contract-term
                         spell.seed/view-term))
    """)

    BeamLisp.Spell.Server.register(
      "chat-live",
      ~s|(first (filter (fn [c] (= (name (get c :name)) "chat-live")) (spell.machine/contracts live-machine)))|
    )

    # The GENERATED module, compiled over the placeholder — exactly what
    # scripts/serve_live.exs does at boot. The fixture socket must name it:
    # `Spacetime.LiveView.push_event/3` checks the push against the module's
    # OWN declarations, so a socket pointing at the placeholder (which declares
    # none) fails every push. That is the guard working, and it cost two failing
    # checks here before the fixture was pointed at the right module.
    generate_server_half()

    results = [
      check("the contract generates a compilable server half", &generated_module/0),
      check("mount seeds every declared assign", &mount_seeds/0),
      check("send appends the message and asks the provider", &send_turn/0),
      check("an empty draft is refused without touching state", &blank_send/0),
      check("streamed tokens accumulate and push", &streaming/0),
      check("the finished answer joins the transcript", &completion/0)
    ]

    failed = Enum.count(results, &(&1 == :error))
    IO.puts("\n#{length(results) - failed}/#{length(results)} checks passed")
    if failed > 0, do: System.halt(1)
  end

  # ── the checks ─────────────────────────────────────────────────────────────

  defp generate_server_half do
    source =
      Compiler.eval_string("""
      (spell.contract/elixir-module spell.seed/contract-term
                                    spell.seed/module
                                    (spell.live/machine-shell live-machine))
      """)

    # The redefinition warning IS the mechanism here (the generated module
    # replaces the placeholder compiled into the app), so it is silenced to keep
    # this script's output about its checks.
    Code.put_compiler_option(:ignore_module_conflict, true)
    Code.compile_string(source)
    Code.put_compiler_option(:ignore_module_conflict, false)
    :ok
  end

  defp generated_module do
    shell = Compiler.eval_string("(spell.live/machine-shell live-machine)")
    if is_nil(shell), do: throw("no &shell in the view term")

    source =
      Compiler.eval_string("""
      (spell.contract/elixir-module spell.seed/contract-term
                                    "SpellWeb.CheckLive"
                                    (spell.live/machine-shell live-machine))
      """)

    # Compiled, not merely emitted: `Spacetime.LiveView.__before_compile__`
    # REFUSES a module whose declared event has no literal handle_event head
    # (E0928), so compiling is what proves the generated heads are real.
    [{module, _} | _] = Code.compile_string(source)
    contract = module.__spacetime_contract__()

    unless Enum.any?(contract.events, &(&1.name == "send")), do: throw("no send event declared")
    unless function_exported?(module, :handle_event, 3), do: throw("no handle_event/3")
    unless function_exported?(module, :handle_info, 2), do: throw("no handle_info/2")

    "#{length(contract.events)} event(s), #{length(contract.assigns)} assign(s), " <>
      "#{length(contract.pushes)} push(es)"
  end

  defp mount_seeds do
    {:ok, socket} = BeamLisp.Spell.Server.mount(socket(), "chat-live")
    keys = socket.assigns |> Map.keys() |> Enum.sort()
    unless :messages in keys and :status in keys and :partial in keys, do: throw(inspect(keys))
    inspect(keys)
  end

  defp send_turn do
    {:reply, reply, socket} =
      BeamLisp.Spell.Server.event(socket(%{messages: [], status: "idle"}), "chat-live", "send", "hello")

    unless reply.tag == "ok", do: throw("expected ok, got #{inspect(reply)}")
    unless length(socket.assigns.messages) == 1, do: throw("message not appended")
    unless socket.assigns.status == "thinking", do: throw("status #{socket.assigns.status}")

    # `ask!` was requested, so the provider must be streaming to THIS process.
    receive do
      {:delta, _id, _chunk} -> "reply=ok, transcript=1, status=thinking, provider streaming"
    after
      5_000 -> throw("no provider message arrived")
    end
  end

  defp blank_send do
    {:reply, reply, socket} =
      BeamLisp.Spell.Server.event(socket(%{messages: [], status: "idle"}), "chat-live", "send", "")

    unless reply.tag == "err", do: throw("expected err, got #{inspect(reply)}")
    unless socket.assigns.messages == [], do: throw("state changed on a refused send")
    "err=#{inspect(reply.reply)}, state untouched"
  end

  defp streaming do
    {:noreply, socket} =
      BeamLisp.Spell.Server.info(
        socket(%{partial: "", status: "thinking", messages: []}),
        "chat-live",
        {:delta, "m1", "hel"}
      )

    {:noreply, socket} =
      BeamLisp.Spell.Server.info(
        socket(Map.drop(socket.assigns, [:__changed__])),
        "chat-live",
        {:delta, "m1", "lo"}
      )

    unless socket.assigns.partial == "hello", do: throw("partial=#{inspect(socket.assigns.partial)}")
    "partial=#{inspect(socket.assigns.partial)}"
  end

  defp completion do
    {:noreply, socket} =
      BeamLisp.Spell.Server.info(
        socket(%{messages: [%{"role" => "user", "text" => "hi"}], partial: "the answer", status: "thinking"}),
        "chat-live",
        {:done, "m1"}
      )

    last = List.last(socket.assigns.messages)
    unless length(socket.assigns.messages) == 2, do: throw("transcript #{inspect(socket.assigns.messages)}")
    unless Map.get(last, "role") == "model", do: throw("role #{inspect(last)}")
    unless socket.assigns.partial == "", do: throw("partial not cleared")
    unless socket.assigns.status == "idle", do: throw("status #{socket.assigns.status}")
    "transcript=2, last=model, partial cleared, status=idle"
  end

  # ── harness ────────────────────────────────────────────────────────────────

  # A socket with no LiveView process behind it. Everything asserted here is a
  # function of assigns, so a bare struct is the honest fixture — and it keeps
  # the check runnable without starting an endpoint.
  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns),
      view: SpellWeb.ChatLive
    }
  end

  defp check(name, fun) do
    detail = fun.()
    IO.puts("  ✓ #{name}\n      #{detail}")
    :ok
  catch
    reason ->
      IO.puts("  ✗ #{name}\n      #{inspect(reason)}")
      :error
  rescue
    e ->
      IO.puts("  ✗ #{name}\n      #{Exception.message(e)}")
      :error
  end
end

IO.puts("\n── the served loop, without a browser ────────────────────────")
ServeLiveCheck.run()
