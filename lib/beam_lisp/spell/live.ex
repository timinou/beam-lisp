defmodule BeamLisp.Spell.Live do
  @moduledoc """
  The loop: a machine, a model, and a page that rebuilds itself.

  One process owns the machine and the transcript. A user message goes to the
  model with the `define` tool offered; a tool call walks the validation ladder;
  an accepted definition re-emits the whole machine, rebuilds the bundle, and
  bumps a version the browser is polling. The page then shows what the model
  just built.

  ## Why the state lives in a process rather than in beam-lisp

  The machine is an immutable value threaded through `spell.define/define`, and
  that is deliberate — rollback is "keep the old one". Something still has to
  hold the current value between turns, and on this runtime that is a process.
  It is deliberately a plain `Agent`-shaped GenServer rather than beam-lisp
  state: `spell.store` exists for exactly this need in-language, but the driver
  also shells out to verse and writes files, so it lives on the Elixir side
  where those already live. When the SELF cluster's hotswap API lands, this
  moves.

  ### The machine is a VALUE in this process's state, not a global var

  It used to be `(def live-machine …)` — a var in the process-global
  `BeamLisp.Env` — and TWO places wrote it: this module's `init/1` and
  `scripts/serve_live.exs`. Last writer won, silently, so a driver started
  after the server read a machine the server had overwritten. There was no way
  to notice: both writes succeed and the loser's definitions simply are not
  there.

  Now the machine is threaded like any other value — `state.machine` in, a new
  machine out — and `candidate` never escapes the function that builds it.
  Rollback becomes what it always claimed to be: not binding the new one.
  Anything that needs the current machine ASKS this process for it, so there is
  exactly one owner and the question "which machine?" has one answer.

  ## What is published, and why a file

  Every accepted definition writes `report.json` next to the bundle: the
  machine's contracts, views, assigns, events, warnings, plus the transcript
  and a version counter. That file IS the repl state — `scripts/peek.sh` reads
  it, the browser polls it, and a human can `cat` it. One artefact, three
  consumers, no protocol.

  ## Retry policy

  A refused proposal is fed back to the model with the failing rung and the
  diagnostic, up to `@max_attempts` times. Every attempt lands in the transcript
  as a `:proposal` entry with its verdict, because a rejected attempt is the
  most informative thing the loop produces and hiding it in stdout would waste
  it. After the last failure the machine is UNCHANGED and the transcript says
  so.
  """

  use GenServer

  alias BeamLisp.Spell
  alias BeamLisp.Spell.Data

  @max_attempts 3
  @tool_name "define"

  # ── the tool the model is offered ─────────────────────────────────────────
  #
  # One tool, two kinds. The schema is deliberately close to the shapes
  # `spell.define/proposal->contract` and `proposal->view` read: a model that
  # fills this in correctly produces a definition that needs no translation,
  # and rung 1 rejects the rest with a reason rather than guessing.
  @define_tool_schema """
  {"type":"object","properties":{\
  "kind":{"type":"string","enum":["contract","view"],"description":"contract = server-owned state and events; view = markup, style and bindings"},\
  "name":{"type":"string","description":"kebab-case, e.g. clock-live or clock"},\
  "rationale":{"type":"string","description":"why this change, in one sentence — it is shown in the chat"},\
  "assigns":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"type":{"type":"string","enum":["list","atom","integer","string","boolean"]}},"required":["name","type"]}},\
  "events":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"params":{"type":"array","items":{"type":"string"}},"replies":{"type":"array","items":{"type":"string","enum":["ok","err"]}}},"required":["name"]}},\
  "pushes":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"fields":{"type":"object"}},"required":["name"]}},\
  "templates":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"params":{"type":"array","items":{"type":"string"}},"html":{"type":"string","description":"one element; {@x.field} interpolates"}},"required":["name","html"]}},\
  "style":{"type":"array","items":{"type":"object","properties":{"selector":{"type":"string"},"rules":{"type":"object"}},"required":["selector","rules"]}},\
  "binds":{"type":"array","items":{"type":"object","properties":{"selector":{"type":"string"},"each":{"type":"object"},"on":{"type":"object"},"view":{"type":"object"}},"required":["selector"]}}},\
  "required":["kind","name","rationale"]}\
  """

  @doc "The tool declaration, as `spell.provider/request-body` wants it."
  def define_tool do
    %{
      name: @tool_name,
      description:
        "Add a contract or a view to the running machine. The definition is emitted, " <>
          "compiled and checked; a rejection returns the compiler's own diagnostic and " <>
          "the machine is left unchanged.",
      parameters: @define_tool_schema
    }
  end

  # ── lifecycle ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    out = Keyword.get(opts, :out, "/tmp/chat-serve")
    File.mkdir_p!(out)

    Spell.init!(["spell.app", "spell.define", "spell.live"])

    state = %{
      out: out,
      machine: seeded_machine(),
      version: 0,
      transcript: [],
      attempts: [],
      last_build: :ok,
      publish: Keyword.get(opts, :publish, true)
    }

    {:ok, publish(state)}
  end

  # The machine every session starts from: the seed contract and the seed view,
  # registered into an empty machine. A value, held in this process's state —
  # see the module doc on why it is no longer a global var.
  defp seeded_machine do
    bl("spell.live", "seeded", [
      bl("spell.machine", "empty-machine", []),
      var("spell.seed", "contract-term"),
      var("spell.seed", "view-term")
    ])
  end

  # ── API ───────────────────────────────────────────────────────────────────

  @doc "The machine's report, the transcript and the version — the repl state."
  def state(server \\ __MODULE__), do: GenServer.call(server, :state, 30_000)

  @doc """
  Apply a proposal directly, without a model. Returns the verdict map.

  This is the same path a tool call takes; it exists so the loop can be driven
  by a scenario file (`scripts/demo.exs`) and by tests, which is what makes the
  whole thing verifiable without a network.
  """
  def define(server \\ __MODULE__, proposal), do: GenServer.call(server, {:define, proposal}, 120_000)

  @doc "One user turn against the real model, with the define tool offered."
  def ask(server \\ __MODULE__, text), do: GenServer.call(server, {:ask, text}, 300_000)

  @doc "Rebuild the page and bump the version, without changing the machine."
  def rebuild(server \\ __MODULE__), do: GenServer.call(server, :rebuild, 120_000)

  @doc """
  Start a turn for a LiveView, streaming the answer back to `reply_to`.

  This is what joins the two halves that used to be separate programs. The
  served page's `(ask! text)` called `spell.provider/stream-async` directly —
  with a cfg carrying NO tools — so the model talking to a browser was
  structurally incapable of proposing anything, while the loop that offers
  `define` was only reachable from a script. One capability, two programs, and
  the one a human can see was the one without it.

  ## The messages

  Sent to `reply_to`, and every one of them is already described by the seed
  contract's `on-info` clauses — which is why this needs no second transport:

      [:delta id chunk]     content arriving, token by token
      [:defined id text]    a proposal was accepted; the page should reload
      [:done id]            the turn ended
      [:failed id why]      it did not

  ## Why a spawned process

  The LiveView must not block: a turn is a network round trip plus, when the
  model proposes, ~2s of verse. Streaming to `reply_to` from a separate process
  is what keeps the page responsive, and it is the same shape
  `spell.provider/stream-async` already had.

  UNLINKED, for the reason that function documents: a provider process that
  dies mid-answer must not take the page down with it. The failure is reported
  as `[:failed …]` instead, which the contract renders.

  The ladder itself runs back INSIDE this GenServer (`define/2`), because the
  machine is this process's state and definitions must be serialised. Two
  browser tabs proposing at once is a race the loop resolves by being one
  process; the ladder answering slowly is what the spawned turn absorbs.
  """
  def ask_async(server \\ __MODULE__, text, reply_to) do
    id = "m#{System.unique_integer([:positive])}"
    cfg = GenServer.call(server, :turn_cfg, 30_000)
    messages = GenServer.call(server, {:record_user, text}, 30_000)

    spawn(fn -> run_turn(server, cfg, messages, reply_to, id) end)
    id
  end

  # ── handlers ──────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:state, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:machine, _from, state), do: {:reply, state.machine, state}

  def handle_call({:define, proposal}, _from, state) do
    {verdict, state} = apply_proposal(proposal, state)
    {:reply, verdict, state}
  end

  def handle_call(:rebuild, _from, state) do
    {:reply, :ok, publish(state)}
  end

  # The cfg a turn runs with: the configured provider PLUS the define tool.
  # Handed out rather than rebuilt by the caller, so "what the model may do"
  # has one definition and the served page cannot end up with a different one.
  def handle_call(:turn_cfg, _from, state), do: {:reply, turn_cfg(), state}

  # Record the user's turn and answer with the conversation to send. Both in
  # one call because they must not interleave: two tabs sending at once would
  # otherwise each build a history missing the other's message.
  def handle_call({:record_user, text}, _from, state) do
    state = say(state, :user, text)
    {:reply, provider_messages(state, text), state}
  end

  # A streamed turn's own answer, recorded when it ends. The spawned process
  # owns the streaming; the transcript stays here, where the machine is.
  def handle_call({:record_model, text}, _from, state) do
    {:reply, :ok, say(state, :model, text)}
  end

  def handle_call({:ask, text}, _from, state) do
    state = say(state, :user, text)
    {reply, state} = turn(state, text, @max_attempts)
    {:reply, reply, state}
  end

  # ── the turn ──────────────────────────────────────────────────────────────
  #
  # Ask the model; if it calls the tool, run the ladder and answer with the
  # verdict; repeat while it keeps proposing, bounded by attempts. A bound is
  # not a nicety: a model that keeps proposing the same rejected definition
  # would otherwise loop until the deadline, and the user would watch a page
  # that never changes.
  @doc """
  The provider cfg a turn runs with: the configured provider PLUS `define`.

  ONE definition of what the model may do. It was two: this module built a cfg
  with `:tools`, and `Spell.Server.maybe_ask/3` called
  `(spell.provider/from-env)` with none — so the model answering a browser
  could not propose anything, and the difference was invisible because both
  paths "worked".
  """
  def turn_cfg do
    Map.put(
      bl("spell.provider", "from-env", []),
      :tools,
      # `:as_written` — these keys are literals in `define_tool/0`, and
      # `spell.provider/tool-decl-json` reads them as keywords.
      Data.to_bl([define_tool()], :as_written)
    )
  end

  # ── a streamed turn, for a LiveView ───────────────────────────────────────
  #
  # Runs in a spawned process. Streams content to `reply_to` as it arrives, and
  # when the model asks for a tool instead, walks the ladder and reports the
  # verdict as prose the page can render.
  defp run_turn(server, cfg, messages, reply_to, id) do
    # `stream` sends to whatever pid it is given, so the turn collects its OWN
    # messages here and forwards them. That is what lets a tool call be
    # intercepted: the page never sees `[:tool-calls …]`, it sees the verdict.
    collector = self()
    bl("spell.provider", "stream-async", [cfg, messages, collector, id])

    collect(server, reply_to, id, [])
  end

  defp collect(server, reply_to, id, acc) do
    receive do
      {:delta, ^id, chunk} ->
        send(reply_to, {:delta, id, chunk})
        collect(server, reply_to, id, [chunk | acc])

      # `:"tool-calls"`, hyphenated: the tuple is built in beam-lisp by
      # `(tuple :tool-calls id calls)`, and a keyword there prints with the
      # hyphen it was written with. Matching `:tool_calls` would compile fine
      # and never fire — the turn would fall through to its timeout.
      {:"tool-calls", ^id, calls} ->
        # A tool turn: the ladder answers, not the model's prose. Handled here
        # rather than forwarded, because `reply_to` is a LiveView and the
        # contract that decodes its messages has no vocabulary for a proposal.
        handle_tool_calls(server, reply_to, id, Data.from_bl(calls))

      {:done, ^id} ->
        finish(server, reply_to, id, acc)

      {:failed, ^id, why} ->
        send(reply_to, {:failed, id, to_string(why)})
    after
      # A provider that accepts a connection and then stalls is the failure this
      # system must survive: without a deadline the collector waits forever and
      # the page's thinking indicator never stops. 180s is the httpc timeout
      # plus room for the ladder.
      180_000 ->
        send(reply_to, {:failed, id, "the provider did not answer within 180s"})
    end
  end

  defp finish(server, reply_to, id, acc) do
    text = acc |> Enum.reverse() |> Enum.join()

    # An answer the page assembled must also reach the TRANSCRIPT, or the next
    # turn is sent a conversation missing its own last reply — and the model
    # answers as if it had said nothing.
    if text != "", do: GenServer.call(server, {:record_model, text}, 30_000)

    send(reply_to, {:done, id})
  end

  # Every call in the turn, walked through the ladder in order.
  #
  # The verdict is sent as `[:defined …]` (accepted) or `[:delta …]` prose
  # (refused). A refusal is DELIBERATELY not `[:failed …]`: the turn did not
  # fail, the proposal did, and the difference is what the user needs to read.
  defp handle_tool_calls(server, reply_to, id, calls) do
    for call <- calls do
      verdict = GenServer.call(server, {:define, parse_arguments(call)}, 300_000)

      case verdict.status do
        :ok ->
          send(reply_to, {:defined, id, "✓ " <> definition_summary(call)})

        _ ->
          send(
            reply_to,
            {:delta, id,
             "✗ the definition was refused at the #{verdict[:rung]} rung: " <>
               "#{first_line(verdict[:reason])}"}
          )
      end
    end

    finish(server, reply_to, id, [])
  end

  defp definition_summary(call) do
    args = parse_arguments(call)
    kind = Map.get(args, "kind", "definition")
    name = Map.get(args, "name", "?")
    why = Map.get(args, "rationale", "")

    "defined #{kind} #{inspect(name)} — #{why}"
  end

  defp first_line(reason) do
    reason
    |> to_string()
    |> String.split("\n")
    |> List.first()
    |> String.slice(0, 300)
  end

  defp turn(state, _text, 0) do
    {%{status: :exhausted, attempts: @max_attempts},
     say(state, :system,
       "no definition accepted after #{@max_attempts} attempts — the machine is unchanged")}
  end

  defp turn(state, text, attempts_left) do
    cfg = turn_cfg()

    turn_result =
      bl("spell.provider", "ask-turn", [
        cfg,
        # Same: `:role` / `:content` are ours, and `message-json` reads
        # keywords. Wire data never takes this path — the model's own words
        # travel as VALUES inside these maps, not as keys.
        Data.to_bl(provider_messages(state, text), :as_written)
      ])

    case decode_turn(turn_result) do
      {:content, answer} ->
        {%{status: :answered, text: answer}, say(state, :model, answer)}

      {:tool_calls, calls} ->
        # Calls are folded with a HALT once one of them retries or fails.
        #
        # The first version reduced over every call and recursed per rejection,
        # so a turn carrying two calls could spend the budget twice — and an
        # arbitrarily long `tool_calls` array multiplied a bound that is
        # supposed to be fixed. A reviewer traced it; the budget is the loop's
        # only protection against a model that proposes forever.
        Enum.reduce_while(calls, {%{status: :answered, text: ""}, state}, fn call, {_acc, st} ->
          {verdict, st} = apply_proposal(parse_arguments(call), st)

          st =
            say(st, :proposal, %{
              name: Map.get(call, "name"),
              verdict: verdict.status,
              rung: Map.get(verdict, :rung),
              reason: Map.get(verdict, :reason)
            })

          case verdict.status do
            :ok -> {:cont, {verdict, st}}
            _ -> {:halt, turn(st, retry_prompt(verdict), attempts_left - 1)}
          end
        end)

      {:error, reason} ->
        {%{status: :error, reason: reason}, say(state, :system, "provider error: #{inspect(reason)}")}
    end
  end

  # A rejection, phrased for the model: the rung that refused and the
  # diagnostic, verbatim. Verse's own text is better than any paraphrase — it
  # names lines and codes, and the model has been trained on far more compiler
  # output than on our prose.
  defp retry_prompt(verdict) do
    "The definition was rejected at the #{verdict[:rung]} rung: " <>
      "#{inspect(verdict[:reason])}. Fix it and call #{@tool_name} again."
  end

  # ── the ladder, all four rungs ────────────────────────────────────────────

  defp apply_proposal(proposal, state) do
    case run_ladder(proposal, state.machine) do
      {:ok, machine, report} ->
        # Commit, then publish — and if publishing FAILS, say so in the verdict
        # rather than reporting success. The machine still holds the definition
        # (it passed every rung; the failure is downstream, in emitting or
        # building), but a caller told `:ok` while the served page is stale has
        # been lied to, and the next proposal would accumulate on state the user
        # never saw.
        state = publish(%{state | machine: machine})

        case state.last_build do
          :ok ->
            {%{status: :ok, report: report}, state}

          {:error, reason} ->
            {%{status: :published_stale, rung: :publish, reason: reason, report: report}, state}
        end

      {:error, verdict} ->
        # The candidate is discarded by simply not returning it: `state.machine`
        # is still the value it was. Rollback is the absence of a write, which
        # is the only kind that cannot half-happen — and now that the machine is
        # a value rather than a global var, it is also the only kind available.
        {verdict, state}
    end
  end

  defp run_ladder(proposal, machine) do
    # The conversion happens BEFORE anything reaches the language, and it refuses
    # what it cannot convert (a struct). A refusal here is a schema rejection,
    # not a crash: a model probing the boundary should get the same bounded
    # answer as one that simply mistyped a field.
    #
    # NB the danger this used to guard is gone rather than handled. The old path
    # PRINTED the proposal as source, so a crafted map key could close the call
    # and open a new form. `BeamLisp.Spell.Data` converts instead: there is no
    # source for a key to break out of, and an unknown key becomes an inert
    # string that rung 1 then reports as a missing field.
    case safe_convert(proposal) do
      {:error, reason} ->
        {:error, %{status: :rejected, rung: :schema, reason: reason}}

      {:ok, converted} ->
        ladder(bl("spell.define", "define", [machine, converted]))
    end
  end

  defp safe_convert(proposal) do
    {:ok, Data.to_bl(proposal, Data.proposal_keys())}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  # Rungs 1–2 answered; run 3–4 against the CANDIDATE's page.
  #
  # `candidate` is a local, so a rejected one is unreachable the moment this
  # returns. It was a global var (`(def candidate …)`), which meant a refused
  # proposal stayed addressable from anywhere until the next one overwrote it.
  defp ladder(candidate) do
    if Map.get(candidate, :status) == :rejected do
      {:error,
       %{
         status: :rejected,
         rung: Map.get(candidate, :rung),
         reason: inspect(Map.get(candidate, :reason))
       }}
    else
      machine = Map.get(candidate, :machine)

      # Rungs 3–4 run against the page the CANDIDATE would produce, never the
      # committed one: checking the current page would pass every proposal.
      page = Path.join(System.tmp_dir!(), "spell_candidate_#{System.unique_integer([:positive])}.st")

      try do
        # The bind selectors are handed to rung 4 so it judges OUR page rather
        # than verse's runtime, which also ships `querySelector` calls.
        selectors = Data.from_bl(bl("spell.live", "machine-bind-selectors", [machine]))

        with {:ok, _} <- Spell.Page.emit(machine, page),
             {:ok, _} <- Spell.Verse.verify(page, selectors) do
          {:ok, machine, bl("spell.live", "machine-report", [machine])}
        else
          {:error, %{rung: rung, reason: reason}} ->
            {:error, %{status: :rejected, rung: rung, reason: reason}}

          {:error, reason} ->
            {:error, %{status: :rejected, rung: :emit, reason: to_string(reason)}}
        end
      after
        File.rm(page)
      end
    end
  end

  # ── publishing ────────────────────────────────────────────────────────────

  defp publish(%{publish: false} = state), do: %{state | last_build: :ok}

  defp publish(state) do
    state = %{state | version: state.version + 1}
    page = Path.join(state.out, "page.st")

    build =
      with {:ok, _} <- Spell.Page.emit(state.machine, page),
           :ok <- build_bundle(page, state.out) do
        :ok
      end

    write_report(state, build)
    %{state | last_build: build}
  end

  defp build_bundle(page, out) do
    with {:ok, bin} <- Spell.Verse.binary() do
      case System.cmd(bin, ["build", Path.expand(page), "-o", Path.expand(out)],
             cd: Spell.Verse.verse_root(),
             stderr_to_stdout: true
           ) do
        {_out, 0} -> :ok
        {out, code} -> {:error, "spacetime build exited #{code}: #{String.trim(out)}"}
      end
    end
  end

  # report.json is the repl state, on disk. Written on every publish INCLUDING
  # a failed build, with the failure in it: a stale report next to a broken
  # bundle would tell the reader the machine is fine while the page they are
  # looking at is not.
  defp write_report(state, build) do
    payload =
      snapshot(state)
      |> Map.put(:build, build_status(build))
      |> Map.put(:at, DateTime.utc_now() |> DateTime.to_iso8601())

    File.write!(Path.join(state.out, "report.json"), JSON.encode!(payload))
  end

  defp build_status(:ok), do: %{ok: true}
  defp build_status({:error, reason}), do: %{ok: false, reason: to_string(reason)}

  defp snapshot(state) do
    %{
      version: state.version,
      transcript: Enum.reverse(state.transcript),
      machine: Data.from_bl(bl("spell.live", "machine-report", [state.machine]))
    }
  end

  @doc """
  The machine this loop currently holds, as a value.

  The ONE way to ask. Everything that needs the live machine — the page
  emitter, the server's contract lookup, a script — asks the process that owns
  it rather than reading a global var, which is what makes "which machine?" a
  question with one answer.
  """
  def machine(server \\ __MODULE__), do: GenServer.call(server, :machine, 30_000)

  # ── transcript ────────────────────────────────────────────────────────────

  defp say(state, role, content) do
    %{state | transcript: [%{role: role, content: content} | state.transcript]}
  end

  # What the provider sees: the user-visible conversation only. Proposals and
  # system notes are for the human reading the page — feeding a model its own
  # rejected proposals as prose, on top of the tool result it already got,
  # doubles them.
  defp provider_messages(state, text) do
    state.transcript
    |> Enum.reverse()
    |> Enum.filter(&(&1.role in [:user, :model]))
    |> Enum.map(&%{role: &1.role, content: &1.content})
    |> conversation(text)
  end

  @doc """
  A transcript plus the current turn, as the provider wants it.

  `history` is `[%{role: :user | :model | "user" | "assistant", content: …}]`;
  the answer is `[%{role: "user" | "assistant", content: …}]` ending in `text`.

  ## Why this is one function and not two

  It was two — here and in `Spell.Server` — and they had already drifted. Both
  translated `model` to `assistant`, and both tried to avoid sending the user's
  current turn twice, by DIFFERENT rules: this one filtered the whole history
  for a matching user entry, the other compared only the last one. The bug that
  costs is not the duplication itself but that the two answers differ: the same
  conversation reached the model differently depending on which half of the
  system asked, and a repeated last message reads to a model as the user
  repeating themselves.

  ## The one rule

  A turn is appended unless the history ALREADY ends with it. Comparing only
  the tail is deliberate: a user who genuinely types "yes" twice in a row has
  said two things, and a whole-history filter silently eats the second.
  """
  def conversation(history, text) do
    messages = Enum.map(history, fn %{role: role, content: content} ->
      %{role: to_role(role), content: to_string(content)}
    end)

    turn = %{role: "user", content: to_string(text)}

    if List.last(messages) == turn, do: messages, else: messages ++ [turn]
  end

  # The contract says `model` (what the page shows); every OpenAI-shaped API
  # says `assistant`. Translated at this boundary and nowhere else.
  defp to_role(:model), do: "assistant"
  defp to_role("model"), do: "assistant"
  defp to_role(other), do: to_string(other)

  # ── plumbing ──────────────────────────────────────────────────────────────

  # `<ns>/<name>` applied to already-converted arguments.
  #
  # Fetched per call rather than cached in a module attribute: `BeamLisp.Env` is
  # where a REDEFINED var lands, so a cached capture would keep running the
  # definition that existed at boot — which in the module whose entire job is
  # growing the system at runtime would be a silent opt-out from its own
  # premise. The lookup is an ETS read against a 118 µs walk.
  defp bl(ns, name, args), do: apply(BeamLisp.Env.fetch!(ns, name), args)

  # A var's VALUE, for the vars that are terms rather than functions.
  defp var(ns, name), do: BeamLisp.Env.fetch!(ns, name)

  defp decode_turn(turn) do
    case Data.from_bl(turn) do
      %{"kind" => "tool-calls", "tool-calls" => calls} -> {:tool_calls, calls}
      %{"kind" => "content", "content" => text} -> {:content, text}
      %{"kind" => "error", "reason" => reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp parse_arguments(%{"arguments" => args}) when is_binary(args) do
    JSON.decode!(args)
  rescue
    e -> %{"_undecodable" => Exception.message(e)}
  end

  defp parse_arguments(other), do: other
end
