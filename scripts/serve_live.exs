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
  @gen "spell/gen"


  def run do
    load_env()
    :inets.start()
    :ssl.start()
    File.mkdir_p!(@out)
    File.mkdir_p!(@gen)

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
    shell = bl("spell.live", "machine-shell", [machine()])

    if is_nil(shell) do
      raise "no view declares an &shell template — there would be nothing for the bundle to hydrate"
    end

    source =
      bl("spell.contract", "elixir-module", [
        BeamLisp.Env.fetch!("spell.seed", "contract-term"),
        BeamLisp.Env.fetch!("spell.seed", "module"),
        shell
      ])

    path = Path.join(@gen, "chat_live.ex")
    File.write!(path, source)
    say("wrote #{path} (#{byte_size(source)} B)")

    [{module, _bin} | _] = Code.compile_file(path)
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

    case BeamLisp.Spell.Live.state().machine do
      %{"errors" => []} -> :ok
      %{"errors" => errors} -> say("machine reports #{length(errors)} error(s): #{inspect(errors)}")
    end

    if File.exists?(page) do
      say("#{page} (#{File.stat!(page).size} B)")
      say("#{bundle_dir()}/spacetime.js + spacetime.css")
    else
      say("PUBLISH FAILED: no page at #{page}")
      say("the browser will 404 its bundle until this is fixed")
    end

    step("SERVE")
    port = Application.get_env(:beam_lisp, SpellWeb.Endpoint)[:http][:port] || 4000

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
