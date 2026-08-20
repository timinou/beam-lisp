# scripts/serve_live.exs — spell, served.
#
#   mix run --no-halt scripts/serve_live.exs
#
# One BEAM node holds the machine, the turn loop, the contract's server half
# and the HTTP endpoint. Beside it, ONE long-running `spacetime serve` process
# (started by the application, see BeamLisp.Spell.Serve) owns everything about
# the view: it watches spell/ui, compiles index.edn, serves the bundle, writes
# build-status.json, and tells browsers to reload.
#
# What this script does, in order:
#
#   1. LOAD      the machine (the default shell: chat + live-state)
#   2. PUBLISH   — the loop emits index.edn and awaits verse's verdict
#   3. RESOLVE   — verify every contract resolves through the loop's machine
#   4. VERIFY    the claims above before printing a URL
#
# The generated module is written to `spell/gen/` and compiled with
# Code.compile_file/1, which REPLACES the placeholder SpellWeb.ChatLive
# compiled into the app. That is ordinary BEAM code loading.

defmodule ServeLive do
  alias BeamLisp.Spell

  def run do
    :inets.start()
    :ssl.start()

    step("LOAD — the machine, and the loop that owns it")
    Spell.init!(["spell.app", "spell.live"])

    # THE LOOP, under its registered name. Not optional, and not a detail:
    # `BeamLisp.Spell.Server.maybe_ask/3` looks for exactly this process, and
    # without it every browser turn silently takes the toolless fallback — the
    # model answers with prose and can propose nothing, which is the ORIGINAL
    # defect this whole plan exists to fix.
    #
    # It also owns the machine. An Agent holding a second copy was the first
    # shape of this and it is the same mistake in a new coat: two owners, and
    # the one the ladder writes to is not the one the page reads from. The loop
    # is the only writer, so `machine/0` asks it.
    {:ok, _} = BeamLisp.Spell.Loop.start_link()

    contracts =
      bl("spell.machine", "contracts", [machine()])
      |> to_list()
      |> Enum.map(&to_string(Map.get(&1, :name)))

    say("contracts: #{inspect(contracts)}")

    step("PUBLISH — index.edn, compiled by verse's serve")

    page = Path.join(BeamLisp.Spell.Build.site_dir(), BeamLisp.Spell.Build.entry())
    say("#{page} (#{File.stat!(page).size} B) — served at #{BeamLisp.Spell.Build.origin()}")

    step("GENERATE — the contract's server half (the loop wrote it during publish)")
    path = Path.join(BeamLisp.Spell.Loop.gen_dir(), "chat_live.ex")

    unless File.exists?(path) do
      abort("the loop did not generate #{path}")
    end

    module = SpellWeb.ChatLive
    say("compiled #{inspect(module)} — #{length(module.__spacetime_contract__().events)} event(s), " <>
          "#{length(module.__spacetime_contract__().assigns)} assign(s), " <>
          "#{length(module.__spacetime_contract__().pushes)} push(es)")

    step("RESOLVE — every contract answers through the one host")
    # Nothing to register: `Spell.Server.contract_term/1` falls back to the
    # loop's machine, so a contract is resolvable the moment the machine holds
    # it — including contracts the model adds AFTER this boot. What there is to
    # do here is verify the resolution works before printing a URL.
    for name <- contracts do
      BeamLisp.Spell.Server.contract_term(name)
    end

    say("#{Enum.join(contracts, ", ")} → the loop's live machine")

    step("VERIFY — this node is what it claims to be")
    port = Application.get_env(:beam_lisp, SpellWeb.Endpoint)[:http][:port] || 4030

    # A server that prints a URL has claimed the URL. The application SKIPS a
    # listener whose port is held, which for a throwaway eval is a kindness and
    # here is a lie: the machine loads, the page compiles, the URL prints — and
    # every request on it is answered by the OTHER node, with the other node's
    # machine and the other node's provider. Verify the claim.
    started = Enum.map(Supervisor.which_children(BeamLisp.Supervisor), &elem(&1, 0))

    unless SpellWeb.Endpoint in started do
      holder =
        case System.cmd("ss", ["-ltnp", "sport = :#{port}"], stderr_to_stdout: true) do
          {out, 0} -> "\n\n" <> String.trim(out)
          _ -> ""
        end

      abort(
        "port #{port} is held by another process, so this node serves NOTHING.\n" <>
          "Stop it first:  pkill -f serve_live.exs\n" <>
          "Or use another: PORT=4031 mix run --no-halt scripts/serve_live.exs" <> holder
      )
    end

    unless BeamLisp.Spell.Serve in started do
      say("NOTE: verse serve is not running in this node (port held or no binary).")
      say("      If another session owns it, its site dir must be THIS project's #{BeamLisp.Spell.Build.site_dir()}")
      say("      or the page and the verdicts describe a different machine.")
    end

    IO.puts("""

       ┌────────────────────────────────────────────┐
       │  http://127.0.0.1:#{port}                      │
       └────────────────────────────────────────────┘

       The page, the seam and the model are one node;
       the view is one `spacetime serve` away.
       Ctrl-C twice to stop.
    """)
  end

  # The current machine — asked of the process that owns it.
  defp machine, do: BeamLisp.Spell.Loop.machine()

  # A failure loud enough to stop the boot. A server that starts and prints a
  # URL has CLAIMED to work; the claim must be false only when the page is.
  defp abort(message) do
    IO.puts(:stderr, "\n" <> message <> "\n")
    System.halt(1)
  end

  defp bl(ns, name, args), do: apply(BeamLisp.Env.fetch!(ns, name), args)
  defp to_list(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp to_list(other), do: other
  defp step(title), do: IO.puts("\n── #{title} " <> String.duplicate("─", max(0, 58 - String.length(title))))
  defp say(text), do: IO.puts("   #{text}")
end

ServeLive.run()
