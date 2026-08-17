# scripts/serve_live.exs — spell, served by spell.
#
#   mix run --no-halt scripts/serve_live.exs
#
# One BEAM node holds the whole loop: the machine, the generated server half,
# the compiled page, the HTTP endpoint and the provider. There is no second
# process serving files and no second app answering the seam.
#
# What this script does, in order — each step is the input to the next:
#
#   1. LOAD      the machine (seed contract + seed view)
#   2. GENERATE  the contract's server half as Elixir source, then COMPILE it
#                — `spell.contract/elixir-module`, the projection that closes
#                the loop: the module the page's `@host` names is emitted from
#                the same term that emits the page
#   3. REGISTER  the contract expression, so the generated module's `@contract`
#                name resolves to a live term
#   4. EMIT      the page (.st) from the machine and BUILD the bundle (verse)
#   5. SERVE     — the endpoint is already up (application.ex starts it for a
#                  `--no-halt` run); this only reports the URL
#
# The generated module is written to `spell/gen/` and compiled with
# `Code.compile_file/1`, which REPLACES the placeholder `SpellWeb.ChatLive`
# compiled into the app. That is ordinary BEAM code loading, and it is the same
# mechanism the SELF cluster will use to let the machine rewrite itself.

defmodule ServeLive do
  alias BeamLisp.Spell

  @out Application.compile_env(:beam_lisp, :spell_static_dir, "/tmp/chat-serve")


  def run do
    load_env()
    :inets.start()
    :ssl.start()
    File.mkdir_p!(@out)

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
    #
    # `publish: true` — an accepted definition must re-emit the page and rebuild
    # the bundle into `@out`, which is what the browser then reloads.
    {:ok, _} = BeamLisp.Spell.Live.start_link(out: @out)

    contracts =
      bl("spell.machine", "contracts", [machine()])
      |> to_list()
      |> Enum.map(&to_string(Map.get(&1, :name)))

    say("contracts: #{inspect(contracts)}")

    step("GENERATE — the contract's server half")
    # The loop generates it, not this script.
    #
    # This step used to lift the shell, emit the module and compile it here —
    # and `Live.publish/1` did not, so the module was written exactly once, at
    # boot. An accepted view redefinition rebuilt `page.st` and the bundle but
    # not the host, and since the shell is rendered SERVER-side the browser
    # kept showing boot's markup through any number of reloads. Observed live:
    # machine at version 3 with the new markup, DOM still at version 1's.
    #
    # Same shape as the PUBLISH step below, which already documents why a
    # second publisher is worse than none: the copies only differ when they
    # disagree, and that is precisely when the wrong one is believed. So the
    # loop owns every artefact an accepted definition invalidates, and this
    # script REPORTS what the loop produced.
    #
    # `Live.start_link/1` above has already published once, so the module
    # exists by now; this reads it rather than rebuilding it.
    path = Path.join(BeamLisp.Spell.Live.gen_dir(), "chat_live.ex")

    unless File.exists?(path) do
      abort("the loop did not generate #{path} — build status: #{inspect(BeamLisp.Spell.Live.state().last_build)}")
    end

    say("loop wrote #{path} (#{File.stat!(path).size} B)")

    module = SpellWeb.ChatLive
    say("compiled #{inspect(module)} — #{length(module.__spacetime_contract__().events)} event(s), " <>
          "#{length(module.__spacetime_contract__().assigns)} assign(s), " <>
          "#{length(module.__spacetime_contract__().pushes)} push(es)")

    step("REGISTER — the contract behind the generated module")
    # A zero-arity FUNCTION, not a value: it runs per event, so a definition
    # accepted later is the one the NEXT event runs against — the property the
    # old source-string form had, kept.
    #
    # Not source, because the registry no longer evaluates beam-lisp:
    # `eval_string` compiled a fresh BEAM module per call, and the atoms
    # interning those module names are never reclaimed.
    BeamLisp.Spell.Server.register("chat-live", &chat_contract/0)

    say("chat-live → live-machine's registered contract")

    step("PUBLISH — the page and the bundle, from the loop")
    # Emitting here was a SECOND publisher. The loop already emits and builds
    # into `@out` on start and after every accepted definition — that is what a
    # browser reloads onto — so a copy here would only differ when they
    # disagreed, which is exactly when it would be believed.
    #
    # `rebuild/1` is the ask: re-emit and rebuild, without changing the
    # machine. The loop has already done it once during `init`; this reports
    # the outcome rather than repeating the work silently.
    :ok = BeamLisp.Spell.Live.rebuild()

    page = Path.join(@out, "page.st")
    bundle = Path.join(bundle_dir(), "spacetime.js")

    case BeamLisp.Spell.Live.state().machine do
      %{"errors" => []} -> :ok
      %{"errors" => errors} -> say("machine reports #{length(errors)} error(s): #{inspect(errors)}")
    end

    # The BUNDLE is what the browser loads, so it is what is checked.
    #
    # Checking only `page.st` was not enough and the gap is not theoretical:
    # `publish/1` writes the page BEFORE running `spacetime build`, so a failed
    # build leaves a perfectly good page beside no bundle. This step then said
    # "published" and the next step printed a URL, and the only place the
    # failure appeared was `report.json`'s `build` field — which nobody reads
    # while a server is starting.
    #
    # `report.json` carries the real verdict, because `publish/1` writes it on
    # every publish INCLUDING a failed one, with the reason in it.
    build = published_build_status()

    cond do
      not File.exists?(page) ->
        abort("PUBLISH FAILED: no page at #{page}. Nothing to serve.")

      match?(%{"ok" => false}, build) ->
        abort("""
        PUBLISH FAILED: #{Map.get(build, "reason")}

        The page emitted but the bundle did not build, so #{bundle} does not
        exist and the browser would load a 404 with no error on this side.
        Refusing to advertise a URL that cannot work.
        """)

      not File.exists?(bundle) ->
        abort("PUBLISH FAILED: no bundle at #{bundle}. The browser would 404.")

      true ->
        say("#{page} (#{File.stat!(page).size} B)")
        say("#{bundle_dir()}/spacetime.js + spacetime.css")
    end

    step("SERVE")
    port = Application.get_env(:beam_lisp, SpellWeb.Endpoint)[:http][:port] || 4000

    # The endpoint is a CONVENIENCE for `mix run -e` and a REQUIREMENT here.
    #
    # `BeamLisp.Application` skips a listener whose port is already held, so a
    # throwaway eval can still run beside a live session. For THIS script that
    # same kindness is a lie: the machine loads, the bundle builds, the URL
    # prints — and every request on it is answered by the OTHER node, with the
    # other node's machine and the other node's provider. Observed: a session
    # left on `PROVIDER=fake` answered turns that a `PROVIDER=glm` boot had
    # announced, and the only symptom was answers that felt wrong.
    #
    # A server that prints a URL has claimed the URL. Verify the claim.
    started = Enum.map(Supervisor.which_children(BeamLisp.Supervisor), &elem(&1, 0))

    unless SpellWeb.Endpoint in started do
      holder =
        case System.cmd("ss", ["-ltnp", "sport = :#{port}"], stderr_to_stdout: true) do
          {out, 0} -> "\n\n" <> String.trim(out)
          _ -> ""
        end

      abort(
        "port #{port} is held by another process, so this node serves NOTHING.\n" <>
          "The machine loaded and the bundle built, but every request would go\n" <>
          "to the other server — a different machine and a different provider.\n\n" <>
          "Stop it first:  pkill -f serve_live.exs\n" <>
          "Or use another: PORT=4031 mix run --no-halt scripts/serve_live.exs" <> holder
      )
    end

    IO.puts("""

       ┌────────────────────────────────────────────┐
       │  http://127.0.0.1:#{port}                      │
       └────────────────────────────────────────────┘

       The page, the seam and the model are one node.
       Ctrl-C twice to stop.
    """)
  end

  # Where the bundle lands — asked of the loop, which builds it.
  #
  # This function used to derive it here while `Spell.Live` built into `@out`
  # itself, so an accepted definition rebuilt into a directory the page never
  # loaded: the browser kept serving the old bundle while `report.json`
  # announced a new version. One derivation now, in the module that does the
  # building.
  # What the last publish actually did, from the loop's own report.
  #
  # `report.json` is written on every publish INCLUDING a failed build, with
  # the reason in it — so it is the honest answer to "is this servable?".
  defp published_build_status do
    @out
    |> Path.join("report.json")
    |> File.read!()
    |> JSON.decode!()
    |> Map.get("build", %{})
  rescue
    _ -> %{}
  end

  # A failure loud enough to stop the boot. A server that starts and prints a
  # URL has CLAIMED to work; the claim must be false only when the page is.
  defp abort(message) do
    IO.puts(:stderr, "\n" <> message <> "\n")
    System.halt(1)
  end

  defp bundle_dir, do: BeamLisp.Spell.Live.bundle_dir(@out, machine())

  # Provider credentials: the real environment, then `.env`, then the agent's
  # credential db. `BeamLisp.Spell.Credentials` owns the precedence — four
  # scripts each carried their own copy of this loader, and they disagreed:
  # three used `File.read!` (crashing without a `.env` that is optional) and
  # three overrode the REAL environment, which silently replaced a caller's
  # `PROVIDER=fake` with `.env`'s paid provider.
  #
  # Loaded here rather than by the provider so a run without credentials still
  # SERVES the page — only `ask!` fails, into the contract's own `[:failed id
  # why]` clause, which the page renders.
  defp load_env do
    case BeamLisp.Spell.Credentials.load() do
      [] -> IO.puts("  (no credentials found — the page serves, but a turn will report a provider error)")
      found -> Enum.each(found, fn {k, src} -> IO.puts("  #{k} ← #{src}") end)
    end
  end

  # The chat contract, looked up in the live machine ON EACH CALL.
  #
  # Called per event by `BeamLisp.Spell.Server`, which is the point: the machine
  # grows as definitions are accepted, and an event must run against the CURRENT
  # contract rather than the one that existed at boot.
  #
  # `contracts` returns a `BeamLisp.Vector`; the `:name` is an ATOM (`:"chat-live"`),
  # not a string, so the comparison converts rather than assuming.
  defp chat_contract do
    bl("spell.machine", "contracts", [machine()])
    |> to_list()
    |> Enum.find(fn c -> to_string(Map.get(c, :name)) == "chat-live" end)
  end

  # The current machine — asked of the process that owns it.
  #
  # One owner, one answer. Anything else is a copy that goes stale the moment a
  # definition lands.
  defp machine, do: BeamLisp.Spell.Live.machine()

  # `<ns>/<name>` applied to values. Fetched per call so a REDEFINED var is the
  # one that runs — the premise of the whole system.
  defp bl(ns, name, args), do: apply(BeamLisp.Env.fetch!(ns, name), args)
  defp to_list(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp to_list(other), do: other
  defp step(title), do: IO.puts("\n── #{title} " <> String.duplicate("─", max(0, 58 - String.length(title))))
  defp say(text), do: IO.puts("   #{text}")
end

ServeLive.run()
