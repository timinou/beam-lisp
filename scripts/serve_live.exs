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
  alias BeamLisp.{Compiler, Spell}

  @out Application.compile_env(:beam_lisp, :spell_static_dir, "/tmp/chat-serve")
  @gen "spell/gen"

  def run do
    load_env()
    :inets.start()
    :ssl.start()
    File.mkdir_p!(@out)
    File.mkdir_p!(@gen)

    step("LOAD — the machine")
    Spell.init!(["spell.app", "spell.live"])

    Compiler.eval_string("""
    (def live-machine
      (spell.live/seeded (spell.machine/empty-machine)
                         spell.seed/contract-term
                         spell.seed/view-term))
    """)

    contracts = eval("(mapv (fn [c] (name (get c :name))) (spell.machine/contracts live-machine))")
    say("contracts: #{inspect(to_list(contracts))}")

    step("GENERATE — the contract's server half")
    shell = eval("(spell.live/machine-shell live-machine)")

    if is_nil(shell) do
      raise "no view declares an &shell template — there would be nothing for the bundle to hydrate"
    end

    source =
      eval("""
      (spell.contract/elixir-module spell.seed/contract-term
                                    spell.seed/module
                                    (spell.live/machine-shell live-machine))
      """)

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

    step("EMIT — the page, from the machine")
    {:ok, page} = Spell.Page.emit("live-machine", Path.join(@out, "page.st"))
    say("#{page} (#{File.stat!(page).size} B)")

    step("BUILD — the bundle (verse)")

    case build(page) do
      {:ok, dir} ->
        say("#{dir}/spacetime.js + spacetime.css")

      {:error, reason} ->
        say("BUILD FAILED: #{reason}")
        say("the page will 404 its bundle until this is fixed")
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

  # The bundle is built into the subdirectory the CONTRACT names. `:bundle` is
  # "/spacetime/chat/spacetime.js" and the endpoint serves `@out` at
  # `/spacetime`, so the build target is `<out>/chat` — derived from the
  # contract rather than agreed by convention, because a mismatch here is a
  # page that loads a 404 and shows nothing, with no error anywhere on the
  # server.
  defp bundle_dir do
    url = eval(~s|(get (get spell.seed/contract-term :opts) :bundle)|)

    dir =
      url
      |> to_string()
      |> String.replace_prefix("/spacetime", "")
      |> Path.dirname()
      |> String.trim_leading("/")

    Path.join([@out | String.split(dir, "/", trim: true)])
  end

  defp build(page) do
    out = bundle_dir()
    File.mkdir_p!(out)

    with {:ok, bin} <- Spell.Verse.binary() do
      case System.cmd(bin, ["build", Path.expand(page), "-o", Path.expand(out)],
             cd: Spell.Verse.verse_root(),
             stderr_to_stdout: true
           ) do
        {_out, 0} -> {:ok, out}
        {out, code} -> {:error, "spacetime build exited #{code}: #{String.trim(out)}"}
      end
    end
  end

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
    BeamLisp.Env.fetch!("spell.machine", "contracts").(Compiler.eval_string("live-machine"))
    |> BeamLisp.Vector.to_list()
    |> Enum.find(fn c -> to_string(Map.get(c, :name)) == "chat-live" end)
  end

  defp eval(src), do: Compiler.eval_string(src)
  defp to_list(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp to_list(other), do: other
  defp step(title), do: IO.puts("\n── #{title} " <> String.duplicate("─", max(0, 58 - String.length(title))))
  defp say(text), do: IO.puts("   #{text}")
end

ServeLive.run()
