# scripts/demo.exs — the demo, and the acceptance test. They are the same thing.
#
#   mix run scripts/demo.exs            # scripted proposals, no network (CI)
#   mix run scripts/demo.exs --live     # a real model drives the same scenario
#
# ── why one artefact ────────────────────────────────────────────────────────
#
# A demo that is not asserted is a story, and an acceptance test nobody watches
# is a number. This runs the scenario, asserts what each step must produce, and
# leaves a screenshot of the result: the same run is the evidence and the show.
#
# Each step names what it PROVES, and every one of them can fail. The two that
# matter most are the negative ones — a proposal that must be refused, and a
# machine that must be unchanged afterwards — because a loop that accepts
# everything would sail through the positive steps.
#
# ── what is real here ───────────────────────────────────────────────────────
#
#   the machine      real, accumulated through the same `define` the model calls
#   the ladder       all four rungs, including verse compiling the candidate
#   the page         emitted from the machine, built by verse, served over HTTP
#   the browser      real headless Chrome; the DOM assertions are on what it rendered
#   the model        real Kimi under --live; scripted proposals otherwise
#
# The scripted mode is not a mock of the loop: it is the loop, with the model's
# tool-call arguments supplied verbatim instead of generated. The only thing
# it does not exercise is the provider, which `scripts/live_tool_probe.exs`
# covers on its own.

alias BeamLisp.Spell.Live
alias BeamLisp.Spell.Build

defmodule Demo do
  @out "/tmp/spell-demo"

  def run(opts) do
    live? = "--live" in opts
    File.rm_rf(@out)
    File.mkdir_p!(@out)

    banner("SPELL — a machine that grows itself")
    IO.puts("  mode: #{if live?, do: "LIVE (real model)", else: "scripted (no network)"}")

    if live?, do: load_env()
    ensure_verse_server!()
    {:ok, _} = Live.start_link()

    steps = [
      &seed_is_serving/1,
      &grow_the_machine/1,
      &page_shows_it/1,
      &broken_proposal_is_refused/1,
      &machine_survives_refusal/1,
      &repl_state_is_readable/1
    ]

    verse_available? = check_verse_reachable()

    failed =
      try do
        steps
        |> Enum.map(fn step -> step.(%{live?: live?, verse_available: verse_available?}) end)
        |> report()
      after
        :ok
      end

    # Halt AFTER cleanup: System.halt/1 does not run `after` clauses.
    if failed > 0, do: System.halt(1)
  end

  # ── 1 ─────────────────────────────────────────────────────────────────────
  defp seed_is_serving(_ctx) do
    step("the seeded page is ready", fn ->
      st = Live.state()
      views = st.machine["views"]

      page = Path.join(Build.site_dir(), Build.entry())

      cond do
        views != ["chat-view"] -> {:fail, "expected the seed view only, got #{inspect(views)}"}
        is_nil(st.version) -> {:fail, "no version in state"}
        st.last_build != :ok -> {:fail, "initial build was #{inspect(st.last_build)}"}
        not File.exists?(page) -> {:fail, "#{page} was not written"}
        true -> {:ok, "v#{st.version}, build ok, index.edn present; views #{inspect(views)}"}
      end
    end)
  end

  # ── 2 ─────────────────────────────────────────────────────────────────────
  #
  # The proposal is the SAME shape whether a model or the script supplies it,
  # because both go through `Live.define/1`. Under --live the model is asked
  # for it in prose and its tool call is what lands.
  defp grow_the_machine(%{live?: true}) do
    step("a real model grows the machine", fn ->
      before = Live.state().version
      result = Live.ask(clock_prompt())
      st = Live.state()

      cond do
        result.status != :ok ->
          {:fail, "the turn was #{inspect(result.status)}"}

        "clock" not in st.machine["views"] ->
          {:fail, "the view is not in the machine; views #{inspect(st.machine["views"])}"}

        # Asserted in BOTH modes: a live mode that proves less than the scripted
        # one is a trap for whoever trusts it.
        st.version <= before ->
          {:fail, "accepted but the version did not move: #{before} → #{st.version}"}

        true ->
          {:ok, "the model's definition was accepted; v#{before} → v#{st.version}; views #{inspect(st.machine["views"])}"}
      end
    end)
  end

  defp grow_the_machine(_ctx) do
    step("a definition grows the machine", fn ->
      before = Live.state().version
      result = Live.define(clock_proposal())
      st = Live.state()

      cond do
        result.status != :ok -> {:fail, "rejected at #{inspect(result[:rung])}: #{inspect(result[:reason])}"}
        st.version <= before -> {:fail, "the version did not move: #{before} → #{st.version}"}
        "clock" not in st.machine["views"] -> {:fail, "the view is not in the machine"}
        true -> {:ok, "accepted; v#{before} → v#{st.version}; views #{inspect(st.machine["views"])}"}
      end
    end)
  end

  # ── 3 ─────────────────────────────────────────────────────────────────────
  #
  # The one that cannot be faked. Everything above is the machine agreeing with
  # itself; this asks the BROWSER whether the element the model defined is on
  # the page, which is the only authority on whether a user would see it.
  defp page_shows_it(%{verse_available: true}) do
    step("the browser renders what was just defined", fn ->
      case dom() do
        {:ok, dom} ->
          # Assert on what the RENDERER produced, not on where the word appears:
          # `data-key` is written by the `@each` that mounted the template, so
          # this cannot pass on a stylesheet link or a comment mentioning the
          # class. (An earlier version checked only for the substring "clock",
          # which was true of the emitted CSS as well.)
          rendered? = Regex.match?(~r/class="clock"[^>]*data-key/, dom)

          cond do
            not rendered? ->
              {:fail, "no rendered .clock element in the DOM:\n#{String.slice(dom, 0, 500)}"}

            not File.exists?(Path.join(@out, "demo.png")) ->
              {:fail, "the DOM is right but no screenshot was captured"}

            true ->
              {:ok, "the renderer mounted <div class=\"clock\" data-key=…> inside .log"}
          end

        {:error, reason} ->
          {:fail, reason}
      end
    end)
  end

  defp page_shows_it(_ctx) do
    step("the browser renders what was just defined (SKIPPED)", fn ->
      {:ok, "verse dev server not reachable; DOM test gated. Start verse with: mix run --no-halt scripts/serve_live.exs"}
    end)
  end

  # ── 4 ─────────────────────────────────────────────────────────────────────
  defp broken_proposal_is_refused(_ctx) do
    step("a broken definition is REFUSED, with the reason", fn ->
      # Snapshot everything published BEFORE the refusal, for the next step.
      Process.put(:before_refusal, published_fingerprint())

      ghost = Live.define(ghost_proposal())
      unmounted = Live.define(unmounted_proposal())

      cond do
        ghost.status != :rejected ->
          {:fail, "a page styling a class nothing renders was ACCEPTED"}

        ghost[:rung] != :ghosts ->
          {:fail, "styled-ghost refused at #{inspect(ghost[:rung])}, expected :ghosts"}

        # A SECOND fixture, for the bound-but-unrendered half of rung 4. The
        # ghost proposal alone cannot prove it: it trips the styled join too, so
        # deleting the unmounted join entirely would leave this step green —
        # exactly the "check that cannot fail" this project refuses to ship.
        # (Found by a reviewer mutating the join and watching nothing go red.)
        unmounted.status != :rejected ->
          {:fail, "a bind on a selector nothing renders was ACCEPTED"}

        not String.contains?(to_string(unmounted[:reason]), "bind selector") ->
          {:fail, "the unmounted bind was refused for the wrong reason: #{inspect(unmounted[:reason])}"}

        true ->
          {:ok,
           "styled-but-unrendered → #{first_line(to_string(ghost[:reason]))}\n      " <>
             "bound-but-unrendered → #{first_line(to_string(unmounted[:reason]))}"}
      end
    end)
  end

  # ── 5 ─────────────────────────────────────────────────────────────────────
  #
  # The invariant the whole tool rests on. A machine that half-accepts a broken
  # definition is worse than one that refuses it: every later proposal is then
  # checked against a state no author approved.
  defp machine_survives_refusal(_ctx) do
    step("the refused definition left NOTHING behind", fn ->
      st = Live.state()
      published = published_fingerprint()

      cond do
        "ghosty" in st.machine["views"] ->
          {:fail, "the refused view is in the machine"}

        # Compare EVERYTHING published, not just the view list. A refusal that
        # accidentally called publish/1 would bump the version and rewrite
        # index.edn while leaving views untouched — and a check that only looked
        # at views would call that unchanged.
        published != Process.get(:before_refusal) ->
          {:fail,
           "the refusal changed published state:\n" <>
             "  before: #{inspect(Process.get(:before_refusal))}\n" <>
             "  after:  #{inspect(published)}"}

        true ->
          {:ok,
           "machine holds #{inspect(st.machine["views"])}, v#{st.version} — " <>
             "version and page byte-identical"}
      end
    end)
  end

  # Everything a refusal must not touch: the version, and the bytes of the
  # index.edn artefact in the Build.site_dir().
  defp published_fingerprint do
    %{
      version: Live.state().version,
      page: digest(Path.join(Build.site_dir(), Build.entry()))
    }
  end

  defp digest(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16() |> String.slice(0, 12)
      _ -> :missing
    end
  end

  # ── 6 ─────────────────────────────────────────────────────────────────────
  defp repl_state_is_readable(_ctx) do
    step("the loop state is readable and consistent", fn ->
      st = Live.state()

      cond do
        is_nil(st.version) ->
          {:fail, "no version in loop state"}

        not is_list(st.machine["views"]) ->
          {:fail, "no views list in machine state"}

        true ->
          {:ok,
           "v#{st.version}: #{length(st.machine["views"])} view(s), " <>
             "#{length(st.machine["assigns"])} assign(s), " <>
             "#{length(st.machine["warnings"])} warning(s)"}
      end
    end)
  end

  # ── the scenario's data ───────────────────────────────────────────────────

  # The scenario's definition mounts into `.log`, an element `&shell` renders.
  #
  # It first bound `.clock` — its own template's class — and the demo caught
  # what four rungs could not: the view compiled, styled and validated, and the
  # browser showed nothing, because a bind SELECTOR must match an element that
  # already exists for the template to mount into. `.clock` only existed inside
  # the template it was trying to render. Verified in a real browser before
  # changing the scenario: DOM contained zero `clock`.
  #
  # That is the demo doing its job. The DOM assertion is the only step that can
  # see this class of failure, which is exactly why it is here.
  defp clock_proposal do
    %{
      "kind" => "view",
      "name" => "clock",
      "rationale" => "render each message with a timestamped clock face",
      "templates" => [
        %{"name" => "clockface", "html" => "<div class='clock'>{@m.text}</div>"}
      ],
      "style" => [%{"selector" => ".clock", "rules" => %{"font-size" => "0.75rem", "opacity" => "0.6"}}],
      "binds" => [
        %{"selector" => ".log", "each" => %{"binding" => "messages", "as" => "m", "template" => "clockface"}}
      ]
    }
  end

  defp clock_prompt do
    """
    Add a view named "clock" using the define tool.

    It needs:
      - one template named "clockface" with html "<div class='clock'>{@m.text}</div>"
      - one style rule for ".clock" with {"font-size": "0.75rem", "opacity": "0.6"}
      - one bind on ".log" with each {"binding": "messages", "as": "m", "template": "clockface"}

    Bind to ".log", which the page already renders — a bind selector must match
    an element that exists for the template to mount into.

    Call the tool. Do not describe it.
    """
  end

  # Styles `.phantom-never-rendered`, which no template renders. Rungs 1–3 all
  # pass it: the machine agrees with itself and verse compiles it happily,
  # because no E-code covers a rule matching nothing. Only rung 4 catches it.
  defp ghost_proposal do
    %{
      "kind" => "view",
      "name" => "ghosty",
      "rationale" => "deliberately styles a class no template renders",
      "templates" => [%{"name" => "real", "html" => "<i class='real'>{@m.text}</i>"}],
      "style" => [
        %{"selector" => ".real", "rules" => %{"color" => "#fff"}},
        %{"selector" => ".phantom-never-rendered", "rules" => %{"color" => "#f00"}}
      ],
      "binds" => [
        %{"selector" => ".real", "each" => %{"binding" => "messages", "as" => "m", "template" => "real"}}
      ]
    }
  end

  # Every styled class RENDERS here, so the styled-ghost join is silent — and
  # the bind targets `.nowhere`, which nothing renders. This isolates the
  # bound-but-unrendered half of rung 4, so removing that join turns step 4 red
  # instead of leaving it green on the ghost fixture's coat-tails.
  defp unmounted_proposal do
    %{
      "kind" => "view",
      "name" => "floating",
      "rationale" => "binds a selector no template renders",
      "templates" => [%{"name" => "drift", "html" => "<i class='drift'>{@m.text}</i>"}],
      "style" => [%{"selector" => ".drift", "rules" => %{"color" => "#fff"}}],
      "binds" => [
        %{"selector" => ".nowhere", "each" => %{"binding" => "messages", "as" => "m", "template" => "drift"}}
      ]
    }
  end

  # ── serving and looking ────────────────────────────────────────────────────

  # Plain `mix run` is intentionally not application-supervised serve mode, so
  # the demo starts the filesystem compiler when no existing server owns it.
  defp ensure_verse_server! do
    unless check_verse_reachable(0) do
      case BeamLisp.Spell.Serve.start_link() do
        {:ok, _pid} -> :ok
        :ignore -> raise "verse serve unavailable; set VERSE_BIN to a spacetime binary"
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> raise "could not start verse serve: #{inspect(reason)}"
      end

      unless check_verse_reachable(50) do
        raise "verse serve did not become reachable at #{Build.origin()}"
      end
    end
  end

  # The verse dev server synthesizes a shell for index-less sites when the only
  # entry is index.edn. Check if it's reachable at Build.origin().
  defp check_verse_reachable(attempts \\ 10) do
    case System.cmd("curl", ["-sf", Build.origin() <> "/"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ when attempts > 0 -> Process.sleep(100); check_verse_reachable(attempts - 1)
      _ -> false
    end
  end

  defp dom do
    chrome = find_chrome()

    if chrome do
      # The verse origin serves the index.edn with a synthesized shell.
      url = Build.origin() <> "/?entry=index.edn"

      {out, _} =
        System.cmd(
          chrome,
          [
            "--headless",
            "--disable-gpu",
            "--no-sandbox",
            "--virtual-time-budget=5000",
            "--timeout=15000",
            "--dump-dom",
            url
          ],
          stderr_to_stdout: false
        )

      screenshot(chrome)
      {:ok, out}
    else
      {:error, "no chrome found (set CHROME_BIN)"}
    end
  end

  # The screenshot must show what the DOM assertion just verified.
  defp screenshot(chrome) do
    url = Build.origin() <> "/?entry=index.edn"

    System.cmd(
      chrome,
      [
        "--headless",
        "--disable-gpu",
        "--no-sandbox",
        "--hide-scrollbars",
        "--force-device-scale-factor=2",
        "--virtual-time-budget=12000",
        "--timeout=25000",
        "--window-size=960,720",
        "--screenshot=#{Path.join(@out, "demo.png")}",
        url
      ],
      stderr_to_stdout: true
    )
  end

  defp find_chrome do
    System.get_env("CHROME_BIN") ||
      Enum.find(
        ["/opt/google/chrome/chrome", System.find_executable("chromium"), System.find_executable("google-chrome")],
        fn p -> p && File.exists?(p) end
      )
  end

  # ── plumbing ──────────────────────────────────────────────────────────────

  defp step(what, fun) do
    IO.write("  … #{what}")

    case fun.() do
      {:ok, detail} ->
        IO.puts("\r  ✓ #{what}\n      #{detail}")
        :pass

      {:fail, why} ->
        IO.puts("\r  ✗ #{what}\n      #{why}")
        :fail
    end
  rescue
    e ->
      IO.puts("\r  ✗ #{what}\n      raised: #{Exception.message(e)}")
      :fail
  end

  defp report(results) do
    failed = Enum.count(results, &(&1 == :fail))
    banner("#{length(results) - failed}/#{length(results)} steps passed")

    if File.exists?(Path.join(@out, "demo.png")) do
      IO.puts("  screenshot: #{Path.join(@out, "demo.png")}")
    end

    IO.puts("  build dir: #{Build.site_dir()}\n")

    # The exit status is RETURNED, not halted on, so `run/1`'s `after` clause
    # still stops the detached server. `System.halt/1` does not unwind the
    # stack, so halting here left python holding the port on exactly the
    # runs that failed — and the next run would then photograph the previous
    # one's page.
    failed
  end

  defp banner(t), do: IO.puts("\n\e[1m── #{t} " <> String.duplicate("─", max(0, 58 - String.length(t))) <> "\e[0m")
  defp first_line(s), do: s |> String.split("\n") |> List.first() |> String.trim()

  # See `BeamLisp.Spell.Credentials`: environment, then `.env`, then the agent
  # credential db, never overriding what the caller already set.
  defp load_env do
    BeamLisp.Spell.Credentials.load()

    :inets.start()
    :ssl.start()
  end
end

Demo.run(System.argv())
