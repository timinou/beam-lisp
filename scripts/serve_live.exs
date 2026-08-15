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
    # The expression, not the value: pointing at `live-machine`'s own lookup
    # means a definition accepted later is the one the NEXT event runs against.
    BeamLisp.Spell.Server.register(
      "chat-live",
      ~s|(first (filter (fn [c] (= (name (get c :name)) "chat-live")) (spell.machine/contracts live-machine)))|
    )

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

  # The provider credentials live in .env (mode 600, gitignored). Loaded here
  # rather than by the provider so a run without credentials still SERVES the
  # page — only `ask!` fails, and it fails into the contract's own `on-info`
  # `[:failed id why]` clause, which the page renders.
  defp load_env do
    case File.read(".env") do
      {:ok, body} ->
        body
        |> String.split("\n")
        |> Enum.each(fn line ->
          case String.split(String.trim(line), "=", parts: 2) do
            # The REAL environment wins over the file. `.env` is a default set,
            # not an override: `PROVIDER=fake mix run …` must select the fake
            # provider even though `.env` names a paid one, or the offline
            # verification path cannot be selected at all.
            [k, v] ->
              if not String.starts_with?(k, "#") and k != "" and System.get_env(k) in [nil, ""],
                do: System.put_env(k, v)
            _ -> :ok
          end
        end)

      _ ->
        IO.puts("  (no .env — the page serves, but a turn will report a provider error)")
    end
  end

  defp eval(src), do: Compiler.eval_string(src)
  defp to_list(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp to_list(other), do: other
  defp step(title), do: IO.puts("\n── #{title} " <> String.duplicate("─", max(0, 58 - String.length(title))))
  defp say(text), do: IO.puts("   #{text}")
end

ServeLive.run()
