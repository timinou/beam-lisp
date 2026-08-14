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
                }
                Err(e) => println!("  {label}: REJECTED — {e}"),
            }
        }
    }
    """

    File.write!("#{@verse}/src/bin/livecheck.rs", src)
    {out, _} = System.cmd("cargo", ~w(run --quiet --bin livecheck), cd: @verse, stderr_to_stdout: false)
    IO.write(out)
    File.rm("#{@verse}/src/bin/livecheck.rs")
  end

  # ── render ───────────────────────────────────────────────────────────────
  defp render(question, reply) do
    esc = fn s -> s |> String.replace("\\", "\\\\") |> String.replace(~s("), ~s(\\")) end

    st = """
    /* Rendered live. The model's reply below came from Kimi k3-256k
       over HTTPS, streamed token by token, at #{DateTime.utc_now() |> DateTime.to_string()}. */
    @import "stdlib/macros/data-kind"
    @import "stdlib/macros/each"

    @data inline $messages : [
      { role: "user",  text: "#{esc.(question)}" },
      { role: "model", text: "#{esc.(reply)}" }
    ];
    @data inline $draft : "";

    @template &bubble($m) {
      <article class="bubble" data-role="`$m.role`">
        <p class="bubble__text">`$m.text`</p>
      </article>
    }

    .log { @each($messages as $m) { &bubble($m); } }
    .composer__input { value <- $draft; @on &.input { $draft <- $.value; } }

    #{File.read!("docs/proof/chat.st") |> String.split("body {") |> List.last() |> then(&("body {" <> &1))}
    """

    File.write!("#{@out}/live.st", st)

    {out, code} =
      System.cmd("bash", ["scripts/shot.sh", "#{@out}/live.st", "docs/proof/chat-live.png", "960", "620"],
        stderr_to_stdout: true)

    IO.write("  " <> out)
    if code != 0, do: IO.puts("  (render failed)")
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
