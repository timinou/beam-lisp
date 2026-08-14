# scripts/live_chat.exs — the whole loop, live, end to end.
#
#   mix run scripts/live_chat.exs
#
# READ    the contract that describes the app (a beam-lisp term)
# REASON  ask a real model a real question, streamed
# EMIT    fold the reply into the transcript, then re-emit the page from the term
# VALIDATE feed the emitted documents through verse's own reader
# LOAD    render the result to a PNG
#
# Everything here talks to the real thing: real Kimi over HTTPS, real verse
# compiler, real headless Chrome. Nothing is stubbed, because the point of this
# script is to be evidence rather than a demonstration.

defmodule LiveChat do
  @verse "/home/user/code/ora/verse"
  @out "/tmp/livechat"

  def run do
    load_env()
    :inets.start()
    :ssl.start()
    File.mkdir_p!(@out)

    BeamLisp.init()
    for f <- ~w(seam contract provider chat) do
      BeamLisp.Compiler.eval_string(File.read!("priv/#{f}.bl"))
    end

    banner("READ — the contract, as data")
    contract = bl(~s|(chat/server-contract)|)
    IO.puts(contract)

    events = bl(~s|(seam/events chat/contract-term)|) |> to_list()
    assigns = bl(~s|(seam/assigns chat/contract-term)|) |> to_list()
    tags = bl(~s|(seam/reply-tags (seam/handler-for chat/contract-term "send"))|) |> to_list()
    IO.puts("\n  events  : #{inspect(events)}")
    IO.puts("  assigns : #{inspect(assigns)}")
    IO.puts("  send can reply with: #{inspect(tags)}")

    banner("REASON — asking Kimi k3-256k, streamed")
    question = "In one short sentence: why does a compiler-checked contract beat a runtime check?"
    IO.puts("  > #{question}\n")

    {reply, deltas, ms} = ask_streamed(question)
    IO.puts("\n\n  #{deltas} deltas in #{ms}ms")

    banner("EMIT — the page, from the same term")
    page = bl(~s|(chat/page-document)|)
    view = bl(~s|(chat/view-page)|)
    File.write!("#{@out}/page.edn", page)
    File.write!("#{@out}/view.edn", view)
    IO.puts("  page.edn  #{byte_size(page)} bytes")
    IO.puts("  view.edn  #{byte_size(view)} bytes")

    banner("VALIDATE — through verse's own reader")
    validate("#{@out}/page.edn", "#{@out}/view.edn")

    banner("LOAD — render the transcript")
    render(question, reply)

    banner("DONE")
  end

  # ── the provider call, streamed ──────────────────────────────────────────
  defp ask_streamed(question) do
    Process.register(self(), :live_target)
    t0 = System.monotonic_time(:millisecond)

    BeamLisp.Compiler.eval_string("""
    (provider/stream-async (provider/from-env)
      [{:role "user" :content #{inspect(question)}}]
      :live_target "turn-1")
    """)

    {chunks, _} = collect([], 0)
    Process.unregister(:live_target)
    {Enum.join(chunks), length(chunks), System.monotonic_time(:millisecond) - t0}
  end

  defp collect(acc, n) do
    receive do
      {:delta, _id, chunk} ->
        IO.write(chunk)
        collect(acc ++ [chunk], n + 1)

      {:done, _id} ->
        {acc, n}

      {:failed, _id, why} ->
        IO.puts("\n  provider failed: #{inspect(why)}")
        {acc, n}
    after
      120_000 ->
        IO.puts("\n  timeout")
        {acc, n}
    end
  end

  # ── validation through verse ─────────────────────────────────────────────
  defp validate(page, view) do
    src = """
    fn main() {
        for (label, path) in [("page", "#{page}"), ("view", "#{view}")] {
            let src = std::fs::read_to_string(path).unwrap();
            match spacetime::edn::to_st_file(&src, &spacetime::syntax::STDLIB_REGISTRY) {
                Ok(f) => {
                    let constructs = f.scopes.iter()
                        .filter(|s| matches!(s.kind, spacetime::parser::ast::ScopeKind::Construct(_)))
                        .count();
                    println!("  {label}: ACCEPTED — {} forms, {} scopes ({} templates)",
                        f.matches.len(), f.scopes.len(), constructs);
                    for m in &f.matches {
                        println!("      {} @ {}", m.macro_name,
                            m.selector.clone().unwrap_or_else(|| "(file)".into()));
                    }
                    // A document can be structurally valid and say NOTHING.
                    // An empty file, or `{:st/forms []}`, yields Ok with zero
                    // matches — the reader has no complaint because there is
                    // nothing to complain about. Accepting that would let the
                    // loop render a page from a document with no content, which
                    // is the failure this gate exists to stop (found by review).
                    if f.matches.is_empty() {
                        println!("  {label}: REJECTED — parsed, but declares no forms");
                        std::process::exit(1);
                    }
                }
                Err(e) => {
                    println!("  {label}: REJECTED — {e}");
                    std::process::exit(1);
                }
            }
        }
    }
    """

    File.write!("#{@verse}/src/bin/livecheck.rs", src)

    {out, status} =
      System.cmd("cargo", ~w(run --quiet --bin livecheck), cd: @verse, stderr_to_stdout: false)

    IO.write(out)
    File.rm("#{@verse}/src/bin/livecheck.rs")

    # A validation step that prints REJECTED and carries on is not validation,
    # it is narration. The reviewer's word for it was fair: the loop reported
    # five green steps whether or not step four agreed.
    #
    # Now a rejected document stops the run, so the LOAD banner below can only
    # be reached by documents verse actually accepted.
    if status != 0 do
      raise """
      verse rejected an emitted document.

      The loop stops here: rendering a page from a document the compiler
      refused would produce a screenshot that proves nothing.
      """
    end
  end

  # ── render ─────────────────────────────────────────────────────────────
  #
  # The page rendered here is built from the EMITTED, VALIDATED documents — the
  # same `(chat/page-document)` and `(chat/view-page)` that step three produced
  # and step four checked.
  #
  # This used to hand-write its own `@template &bubble` and its own `@each`, so
  # the screenshot at the end of a five-step loop was a picture of a page the
  # loop had not produced. A reviewer put it plainly: the steps were real but
  # disconnected. Emitting a document, validating it, then rendering something
  # else proves each step in isolation and the seam not at all.
  #
  # The model's reply now enters as DATA — the assign a LiveView would push —
  # while every template, style rule and binding comes from the term.
  defp render(question, reply) do
    seam = print_st("#{@out}/page.edn")
    view = print_st("#{@out}/view.edn")

    st = """
    /* Rendered live. The model's reply came from Kimi k3-256k over HTTPS,
       streamed token by token, at #{DateTime.utc_now() |> DateTime.to_string()}.

       The reply is DATA. Everything between the markers is emitter output,
       printed from the documents step four validated. */
    @import "stdlib/macros/data-kind"
    @import "stdlib/macros/each"
    @import "stdlib/macros/on"
    @import "stdlib/macros/host"
    @import "stdlib/macros/handle"

    @host $chat : live("SpacetimeLvWeb.ChatLive")

    @data inline $draft : "";

    /* ── emitted: the seam (defcontract) ───────────────────────────── */
    #{seam}
    /* ── emitted: the view (defview) ─────────────────────────────── */
    #{view}
    /* ── end emitted ───────────────────────────────────────────── */

    /* PRESENTATION — hand-written, borrowed from docs/proof/chat.st.

       These rules come AFTER the emitted ones and can override them at equal
       specificity, so a regression in the style plane would not necessarily
       change this picture. A reviewer flagged that, and it is worth being plain
       about: the screenshot is evidence for the MARKUP and BINDS planes, and
       only partial evidence for style. The `.log`/`.bubble`/`.composer` rules
       the term emits are present above; what follows is typography, spacing and
       colour that no contract has an opinion about. */
    #{File.read!("docs/proof/chat.st") |> String.split("body {") |> List.last() |> then(&("body {" <> &1))}
    """

    File.write!("#{@out}/live.st", st)

    # `$messages` is a SUBSCRIPTION in the emitted seam: it initialises to null
    # and waits for the server. Declaring it inline here would declare the same
    # binding twice and the subscription's null would win — a page that compiles
    # perfectly and renders an empty log. So the transcript arrives the way the
    # bridge delivers it: a write to `window.SpacetimeLocal`.
    seed =
      JSON.encode!([
        %{"role" => "user", "text" => question},
        %{"role" => "model", "text" => reply}
      ])

    # The mount point comes from the emitted `&shell`, not a copy of it. The
    # renderer binds onto this skeleton, so it must exist before the bundle
    # runs — but taking it from the emitted text means a change to `&shell`
    # changes this page, which a hand-copied skeleton would not.
    shell =
      case Regex.run(~r/@template &shell\(\) \{(.*?)\}\s*$/m, view) do
        [_, markup] -> String.trim(markup)
        _ -> raise "the emitted view declares no &shell — nothing to mount onto"
      end

    File.write!("#{@out}/live.host.html", """
    <!doctype html>
    <html><head><meta charset="utf-8"><link rel="stylesheet" href="spacetime.css"></head>
    <body>
      #{shell}
      <script src="spacetime.js"></script>
      <script>
        (function () {
          var seed = #{seed};
          function push() {
            if (!window.SpacetimeLocal) return false;
            window.SpacetimeLocal["messages"] = seed;
            document.dispatchEvent(new CustomEvent("local:messages:updated", { detail: seed }));
            return true;
          }
          if (!push()) {
            var t = setInterval(function () { if (push()) clearInterval(t); }, 10);
            setTimeout(function () { clearInterval(t); }, 4000);
          }
        })();
      </script>
    </body></html>
    """)

    {out, code} =
      System.cmd(
        "bash",
        ["scripts/shot.sh", "#{@out}/live.st", "docs/proof/chat-live.png", "960", "620"],
        env: [
          {"HOST_HTML", Path.expand("#{@out}/live.host.html")},
          # The image must show the transcript, not the empty skeleton. Byte
          # size cannot tell those apart; the DOM can.
          {"SHOT_REQUIRE", ~s(data-role="model")}
        ],
        stderr_to_stdout: true
      )

    IO.write("  " <> out)

    if code != 0 do
      raise "the live render failed — refusing to leave a stale screenshot in place"
    end
  end

  # An emitted EDN document as `.st`, via verse's own printer.
  defp print_st(path) do
    {out, 0} =
      System.cmd("cargo", ["run", "--quiet", "--bin", "spacetime", "--", "st", Path.expand(path)],
        cd: @verse
      )

    String.trim(out)
  end

  # ── helpers ──────────────────────────────────────────────────────────────
  defp bl(src), do: BeamLisp.Compiler.eval_string(src)

  defp to_list(%BeamLisp.Vector{} = v), do: BeamLisp.Vector.to_list(v)
  defp to_list(l) when is_list(l), do: l
  defp to_list(other), do: [other]

  defp banner(t), do: IO.puts("\n\e[1m── #{t} " <> String.duplicate("─", max(0, 60 - String.length(t))) <> "\e[0m")

  defp load_env do
    ".env"
    |> File.read!()
    |> String.split("\n")
    |> Enum.each(fn line ->
      case String.split(String.trim(line), "=", parts: 2) do
        [k, v] -> if not String.starts_with?(k, "#") and k != "", do: System.put_env(k, v)
        _ -> :ok
      end
    end)
  end
end

LiveChat.run()
