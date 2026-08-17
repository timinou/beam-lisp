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
  "templates":{"type":"array","description":"a view MUST include one named `shell` — the whole-page template the browser hydrates into; any other name and there is no page","items":{"type":"object","properties":{"name":{"type":"string","description":"`shell` for the page itself; anything else for a part it hosts"},"params":{"type":"array","items":{"type":"string"}},"html":{"type":"string","description":"one element; {@x.field} interpolates"}},"required":["name","html"]}},\
  "style":{"type":"array","items":{"type":"object","properties":{"selector":{"type":"string"},"rules":{"type":"object"}},"required":["selector","rules"]}},\
  "binds":{"type":"array","description":"each item attaches EXACTLY ONE of each/on/view to a selector","items":{"type":"object","properties":{\
  "selector":{"type":"string"},\
  "each":{"type":"object","description":"repeat a template over a list assign","properties":{"binding":{"type":"string","description":"the list assign, e.g. messages"},"as":{"type":"string","description":"name each item is bound to inside the template, e.g. m"},"template":{"type":"string","description":"name of a template defined in this same proposal"}},"required":["binding","template"]},\
  "on":{"type":"object","description":"a DOM event; MUST carry either fire or value, never neither","properties":{"event":{"type":"string","description":"click, input, keydown… (default click)"},"fire":{"type":"string","description":"name of a declared contract event to send"},"arg":{"type":"string","description":"value passed with the fired event, e.g. a page-local like draft"},"value":{"type":"string","description":"write to a page-local instead of firing, e.g. draft"},"key":{"type":"string","description":"only with event keydown: fire only for this key, e.g. Enter"}}},\
  "view":{"type":"object","description":"swap templates by the value of an assign","properties":{"binding":{"type":"string","description":"the assign to switch on, e.g. status"},"arms":{"type":"array","description":"[value, template-name] pairs","items":{"type":"array","items":{"type":"string"}}}},"required":["binding","arms"]}},\
  "required":["selector"]}}},\
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

    # EVERYTHING that can block runs in the spawned process, including the two
    # calls into the loop.
    #
    # They used to run here, in the LiveView's own process, and that is a stall
    # a user feels: the loop is single-threaded and a ladder run holds it for
    # ~4s (two `spacetime` invocations). A second tab pressing Send during that
    # window blocked in `handle_event` — the page frozen, no thinking
    # indicator, no way to tell whether the click registered.
    #
    # Worse, a `GenServer.call` to a dead or overloaded loop EXITS the caller,
    # and the caller was the LiveView: the browser's socket dropped and the
    # transcript went with it. Now the failure is a `[:failed …]` message the
    # contract renders.
    spawn(fn -> start_turn(server, text, reply_to, id) end)
    id
  end

  # A turn, from the spawned process: ask the loop what to send, then stream.
  #
  # Wrapped so that NOTHING can leave the page without an answer. A crash here
  # — the loop down, a timeout, a bug in the ladder — used to mean the
  # collector never sent `[:done …]`, and the page's thinking indicator ran
  # forever with no error and no recovery short of a reload. `@status` stuck on
  # `:thinking` is the single most confusing state this system can produce,
  # because it is indistinguishable from a slow model.
  defp start_turn(server, text, reply_to, id) do
    cfg = GenServer.call(server, :turn_cfg, 30_000)
    messages = GenServer.call(server, {:record_user, text}, 30_000)
    run_turn(server, cfg, messages, reply_to, id)
  catch
    kind, reason ->
      send(reply_to, {:failed, id, "the turn could not start: #{inspect({kind, reason})}"})
  end

  # ── handlers ──────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:state, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:machine, _from, state), do: {:reply, state.machine, state}

  def handle_call(:transcript, _from, state),
    do: {:reply, Enum.reverse(state.transcript), state}

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
  defp run_turn(server, cfg, messages, reply_to, id, attempts_left \\ @max_attempts) do
    # `stream` sends to whatever pid it is given, so the turn collects its OWN
    # messages here and forwards them. That is what lets a tool call be
    # intercepted: the page never sees `[:tool-calls …]`, it sees the verdict.
    collector = self()
    bl("spell.provider", "stream-async", [cfg, messages, collector, id])

    collect(server, cfg, messages, reply_to, id, [], attempts_left)
  end

  defp collect(server, cfg, messages, reply_to, id, acc, attempts_left) do
    receive do
      {:delta, ^id, chunk} ->
        send(reply_to, {:delta, id, chunk})
        collect(server, cfg, messages, reply_to, id, [chunk | acc], attempts_left)

      # `:"tool-calls"`, hyphenated: the tuple is built in beam-lisp by
      # `(tuple :tool-calls id calls)`, and a keyword there prints with the
      # hyphen it was written with. Matching `:tool_calls` would compile fine
      # and never fire — the turn would fall through to its timeout.
      {:"tool-calls", ^id, calls} ->
        # A tool turn: the ladder answers, not the model's prose. Handled here
        # rather than forwarded, because `reply_to` is a LiveView and the
        # contract that decodes its messages has no vocabulary for a proposal.
        handle_tool_calls(server, cfg, messages, reply_to, id, Data.from_bl(calls), attempts_left)

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
    #
    # But `[:done …]` is sent WHATEVER happens to that record. A failed
    # bookkeeping call must not cost the user their answer AND leave the
    # thinking indicator spinning: the page already holds the streamed text in
    # `@partial`, and `done` is what commits it. Losing the loop's copy costs
    # the NEXT turn some context; losing `done` costs this one entirely.
    try do
      if text != "", do: GenServer.call(server, {:record_model, text}, 30_000)
    catch
      kind, reason ->
        require Logger
        Logger.warning("spell.live: the transcript did not record a turn: #{inspect({kind, reason})}")
    end

    send(reply_to, {:done, id})
  end

  # Every call in the turn, walked through the ladder in order.
  #
  # The verdict is sent as `[:defined …]` (accepted) or `[:delta …]` prose
  # (refused). A refusal is DELIBERATELY not `[:failed …]`: the turn did not
  # fail, the proposal did, and the difference is what the user needs to read.
  defp handle_tool_calls(server, cfg, messages, reply_to, id, calls, attempts_left) do
    verdicts =
      for call <- calls do
        # A ladder that crashes is reported, not propagated: the spawned turn
        # dying here would take `[:done …]` with it and strand the page.
        verdict =
          try do
            GenServer.call(server, {:define, parse_arguments(call)}, 300_000)
          catch
            kind, reason ->
              %{status: :error, rung: :loop, reason: inspect({kind, reason})}
          end

        # A verdict is recorded in the loop's transcript as well as sent to the
        # page, and that is not bookkeeping — it is what survives the reload.
        #
        # An accepted definition rebuilds the page, the browser reloads, and the
        # LiveView remounts seeding from this transcript. A verdict that lived
        # only in the socket's assigns disappeared at exactly the moment its
        # definition arrived: the user saw the clock appear and the sentence
        # explaining it vanish.
        text =
          case verdict.status do
            :ok ->
              "✓ " <> definition_summary(call)

            _ ->
              # A refusal is its OWN `[:defined …]` message, not a `[:delta …]`.
              #
              # As a delta it accumulated into `@partial`, and the next accepted
              # call's `[:defined …]` cleared that buffer — so on a turn
              # proposing two things, one refused and one accepted, the user saw
              # the success and never learned why the other was rejected.
              #
              # Every verdict is a completed statement about a proposal, so every
              # verdict lands in the transcript as its own turn. `[:defined …]`
              # is named for the EVENT (a definition was decided), not for the
              # outcome; the text carries ✓ or ✗.
              "✗ the definition was refused at the #{verdict[:rung]} rung: " <>
                "#{first_line(verdict[:reason])}"
          end

        record(server, text)
        send(reply_to, {:defined, id, text})
        verdict
      end

    retry_or_finish(server, cfg, messages, reply_to, id, verdicts, attempts_left)
  end

  # A refused proposal is fed BACK to the model, with the failing rung and the
  # diagnostic, up to `@max_attempts` times.
  #
  # This is what `turn/3` — the synchronous path a script drives — has always
  # done, and the browser path did not: a rejected proposal simply ended the
  # turn, so a user watching the page got one attempt while a script got three.
  # Two behaviours behind one capability is the thing PLAN-027 exists to remove,
  # and joining the loops in W3 joined the CODE without joining this.
  #
  # The retry runs in THIS process, which is already the spawned turn, so the
  # page keeps streaming and the LiveView still never blocks.
  defp retry_or_finish(server, cfg, messages, reply_to, id, verdicts, attempts_left) do
    rejected = Enum.reject(verdicts, &(&1.status == :ok))

    cond do
      rejected == [] ->
        finish(server, reply_to, id, [])

      attempts_left <= 1 ->
        # The budget is the loop's only protection against a model that
        # proposes forever, and the user is TOLD it ran out rather than left
        # with a silent last refusal.
        text = "no definition accepted after #{@max_attempts} attempts — the machine is unchanged"
        record(server, text)
        send(reply_to, {:defined, id, text})
        finish(server, reply_to, id, [])

      true ->
        # DRAIN the `[:done …]` this turn's stream is about to send.
        #
        # `stream/4` sends `[:tool-calls …]` and THEN `[:done …]`, so by the
        # time the ladder has answered, a `:done` for this id is already in
        # flight. Starting the retry without taking it means the next
        # `collect` receives the OLD turn's `:done`, finishes immediately, and
        # the retry's own messages arrive with nobody listening — which is
        # exactly what happened: one refusal, no second attempt, and the
        # budget silently unused.
        #
        # A short timeout rather than a blocking receive: if the stream failed
        # instead of completing, no `:done` is coming and waiting for one would
        # hang the turn.
        receive do
          {:done, ^id} -> :ok
        after
          5_000 -> :ok
        end

        # Verse's own text, verbatim: it names lines and codes, and the model
        # has been trained on far more compiler output than on our prose.
        prompt = retry_prompt(hd(rejected))
        next = messages_with_retry(messages, prompt)

        run_turn(server, cfg, next, reply_to, id, attempts_left - 1)
    end
  end

  # The conversation plus a correction turn. Built here rather than in the loop
  # because a retry is not something the USER said, and it must not reach the
  # transcript the page renders.
  #
  # `:as_written` and KEYWORD keys, both load-bearing:
  # `spell.provider/message-json` reads `(get m :role)`, so a string-keyed map
  # serialises as `{"role":"","content":""}` — a request full of blank turns,
  # accepted by the provider and answered as if the user had said nothing.
  # Caught by printing the request body rather than trusting the round trip.
  defp messages_with_retry(messages, prompt) do
    existing =
      messages
      |> Data.from_bl()
      |> Enum.map(&%{role: Map.get(&1, "role", "user"), content: Map.get(&1, "content", "")})

    Data.to_bl(existing ++ [%{role: "user", content: prompt}], :as_written)
  end

  # Record a model turn, tolerating a loop that cannot answer. See `finish/4`:
  # losing the record costs the next turn some context, and must never cost
  # this turn its `[:done …]`.
  defp record(server, text) do
    GenServer.call(server, {:record_model, text}, 30_000)
  catch
    kind, reason ->
      require Logger
      Logger.warning("spell.live: a verdict did not reach the transcript: #{inspect({kind, reason})}")
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
           :ok <- build_bundle(page, state.out, state.machine),
           :ok <- regenerate_host(state.machine) do
        :ok
      end

    write_report(state, build)
    %{state | last_build: build}
  end

  # The host module carries the SHELL — the markup a LiveView renders for the
  # bundle to hydrate into — and `spell.live/machine-shell` lifts that shell
  # from the machine's `&shell` template. So a view redefinition changes the
  # shell, and the module must be rebuilt with it.
  #
  # This ran only at boot, in `scripts/serve_live.exs`. The consequence, found
  # by asking a live model to redefine the chat view and then reading the DOM:
  # the definition was ACCEPTED, `page.st` and the bundle were rebuilt with the
  # new markup, `report.json` announced version 3 — and the browser kept
  # rendering the shell generated at boot. A hard reload changed nothing,
  # because the stale markup was being rendered server-side by a module nobody
  # had regenerated. Machine grew; page could not.
  #
  # That is the SAME defect `bundle_dir/2` below documents ("a machine that
  # grows and a page that never changes, with no error anywhere") — it was
  # fixed for the bundle and missed for the host, because the two halves of
  # publishing lived in two files. Both now live here: whatever an accepted
  # definition changes, the loop rebuilds all of it, and the boot script asks
  # the loop rather than doing half the job itself.
  #
  # Failure is returned, never raised: a machine whose views declare no shell
  # is a refusable state, and `last_build` is where refusals are already
  # reported to the report and the transcript.
  defp regenerate_host(machine) do
    case bl("spell.live", "machine-shell", [machine]) do
      nil ->
        {:error,
         "no view declares an &shell template — there would be nothing for the bundle to hydrate"}

      shell ->
        source =
          bl("spell.contract", "elixir-module", [
            BeamLisp.Env.fetch!("spell.seed", "contract-term"),
            BeamLisp.Env.fetch!("spell.seed", "module"),
            shell
          ])

        path = Path.join(gen_dir(), "chat_live.ex")
        File.mkdir_p!(gen_dir())
        File.write!(path, source)

        # Compiling REPLACES the running module in the code server, which is
        # the whole point: the next request renders the new shell. Warnings are
        # silenced because regenerating an existing module legitimately
        # redefines it, and that warning on every accepted definition would
        # train the reader to ignore the log.
        Code.put_compiler_option(:ignore_module_conflict, true)

        try do
          [{_module, _bin} | _] = Code.compile_file(path)
          :ok
        rescue
          e -> {:error, "the generated host module did not compile: #{Exception.message(e)}"}
        after
          Code.put_compiler_option(:ignore_module_conflict, false)
        end
    end
  end

  @doc "Where the generated server half is written."
  def gen_dir, do: Application.get_env(:beam_lisp, :spell_gen_dir, "spell/gen")

  defp build_bundle(page, out, machine) do
    target = bundle_dir(out, machine)
    File.mkdir_p!(target)

    with {:ok, bin} <- Spell.Verse.binary() do
      case System.cmd(bin, ["build", Path.expand(page), "-o", Path.expand(target)],
             cd: Spell.Verse.verse_root(),
             stderr_to_stdout: true
           ) do
        {_out, 0} -> :ok
        {out, code} -> {:error, "spacetime build exited #{code}: #{String.trim(out)}"}
      end
    end
  end

  @doc """
  Where the bundle for `machine` belongs under `out`.

  DERIVED from the contract's own `:bundle` option, never agreed by convention.
  The contract says `"/spacetime/chat/spacetime.js"` and the endpoint serves
  `out` at `/spacetime`, so the build target is `<out>/chat`.

  This existed only in `scripts/serve_live.exs` while the loop built into `out`
  itself — so an accepted definition rebuilt into a directory the page never
  loads. The browser would keep serving the old bundle while `report.json`
  announced a new version, and the page would reload onto exactly what it was
  already showing: a machine that grows and a page that never changes, with no
  error anywhere. One derivation, so the two cannot disagree.

  Falls back to `out` when no contract declares a bundle — a machine with no
  contracts has no page to place, and guessing a subdirectory would be worse
  than putting it where the caller asked.
  """
  def bundle_dir(out, machine) do
    case bundle_url(machine) do
      nil ->
        out

      url ->
        sub =
          url
          |> to_string()
          |> String.replace_prefix("/spacetime", "")
          |> Path.dirname()
          |> String.trim_leading("/")

        Path.join([out | String.split(sub, "/", trim: true)])
    end
  end

  defp bundle_url(machine) do
    bl("spell.machine", "contracts", [machine])
    |> BeamLisp.Vector.to_list()
    |> Enum.find_value(fn contract ->
      contract |> Map.get(:opts, %{}) |> Map.get(:bundle)
    end)
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

  @doc """
  The conversation, shaped as the page's `@messages` assign.

  `[%{"role" => "user" | "model", "text" => …}]` — what a mount seeds with, so a
  browser that reloads finds the conversation it was having.

  ## Why this exists

  The page reloads itself when the machine grows: that is the whole point, and
  it is triggered by the version in `report.json` moving. But a reload remounts
  the LiveView, and `mount` seeds from the contract's DECLARED INITIALS — an
  empty transcript. So asking for a clock worked, the page rebuilt, and the
  conversation that asked for it disappeared. Observed in a browser: the user
  sees their message vanish at the exact moment the thing they asked for
  arrives, which reads as the send having failed.

  The loop already holds the transcript, because it is the thing that survives
  a page. Seeding from it is what makes the reload invisible.

  Only user and model turns: `:system` notes and `:proposal` entries are for
  the report and the console, not for a chat bubble.
  """
  def transcript_messages(server \\ __MODULE__) do
    server
    |> GenServer.call(:transcript, 30_000)
    |> Enum.filter(&(&1.role in [:user, :model]))
    |> Enum.map(fn %{role: role, content: content} ->
      %{"role" => to_string(role), "text" => to_string(content)}
    end)
  end

  # ── transcript ────────────────────────────────────────────────────────────

  defp say(state, role, content) do
    %{state | transcript: [%{role: role, content: content} | state.transcript]}
  end

  # What the provider sees: the user-visible conversation only. Proposals and
  # system notes are for the human reading the page — feeding a model its own
  # rejected proposals as prose, on top of the tool result it already got,
  # doubles them.
  defp provider_messages(state, text) do
    conversation =
      state.transcript
      |> Enum.reverse()
      |> Enum.filter(&(&1.role in [:user, :model]))
      |> Enum.map(&%{role: &1.role, content: &1.content})
      |> conversation(text)

    # The briefing goes FIRST, and it is rebuilt from the CURRENT machine on
    # every turn rather than captured once.
    #
    # Without it the model has a tool for editing a machine and no knowledge of
    # the machine: asked to improve the chat view, glm-5.3 reasoned "since I
    # can't inspect the machine, I should define a view that binds to a standard
    # chat contract shape", invented four names that do not exist, and was
    # correctly refused by the ladder. The refusal was right; withholding the
    # vocabulary was ours.
    #
    # Rebuilt per turn because the machine is the thing being edited: a view
    # accepted this turn must appear in the next turn's briefing, or the model
    # is reasoning about a system one definition out of date — which for a
    # multi-step change is the same failure in slower motion.
    [%{role: "system", content: bl("spell.live", "machine-briefing", [state.machine])} | conversation]
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

  # A var's VALUE, for the vars that are terms rather than functions.
  defp var(ns, name), do: BeamLisp.Env.fetch!(ns, name)

  # CALL a beam-lisp fn with ordinary Elixir data.
  #
  # The whole point of PLAN-027: a beam-lisp var IS an Elixir fn value, so
  # reaching spell's reasoning is `fetch` + `apply` — never printing arguments
  # as source for `Compiler.eval_string/1`. That printing path cost 8_176 µs
  # against 118 µs here, and worse than the time: it compiled a FRESH BEAM
  # module per call, interning atoms that are never reclaimed. `Server.info/3`
  # ran it once per streamed token, so a 500-token answer leaked ~1000 modules
  # toward an atom limit whose exhaustion aborts the VM uncatchably.
  #
  # The lookup is deliberately NOT cached, for the reason `Spell.Server` states
  # at its own `apply_bl`: `BeamLisp.Env` is where a REDEFINED var lands, and a
  # cached capture would keep running the definition that existed at boot —
  # opting this module out of the hot redefinition that is the system's point.
  # An ETS read (~1 µs) against a 118 µs walk is not worth that.
  defp bl(ns, name, args) do
    fun = BeamLisp.Env.fetch!(ns, name)

    unless is_function(fun, length(args)) do
      raise ArgumentError,
            "#{ns}/#{name} is not a function of #{length(args)} argument(s) — got #{inspect(fun)}"
    end

    apply(fun, args)
  end

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
