defmodule BeamLisp.Spell.Loop do
  @moduledoc """
  The loop: a machine, a model, and a page that rebuilds itself.

  One process owns the machine and the transcript. A user message goes to the
  model with the `run` tool offered; a tool call's SOURCE walks the validation
  ladder; an accepted definition re-emits the whole machine, awaits verse's
  build verdict, and the browser's shell reloads on verse's dev websocket. The
  page then shows what the model just built.

  ## Why the state lives in a process rather than in beam-lisp

  The machine is an immutable value threaded through `spell.run/run`, and
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

  ## What is published, and how the browser learns of it

  An accepted definition writes the whole machine's page as ONE EDN document
  to the served site dir (`Spell.Build.site_dir/0`). A running `spacetime
  serve` watches that dir, compiles the document, records its verdict in
  `build-status.json` (which this process awaits), and announces Reload on
  its own dev websocket — the browser's shell listens for exactly that. No
  bundle is built or served by this app; there is no report.json and no
  polling.

  ## Retry policy

  A refused definition is fed back to the model with the failing rung and the
  diagnostic, up to `@max_attempts` times. Every attempt lands in the transcript
  as a `:run` entry with its verdict, because a rejected attempt is the
  most informative thing the loop produces and hiding it in stdout would waste
  it. After the last failure the machine is UNCHANGED and the transcript says
  so.
  """

  use GenServer

  alias BeamLisp.Spell
  alias BeamLisp.Spell.Data

  @max_attempts 3
  @tool_name "run"

  # ── the tool the model is offered ─────────────────────────────────────────
  #
  # One tool, one argument that matters: SOURCE — the very `(defcontract …)` /
  # `(defview …)` text a human author would write. The previous schema asked
  # for a JSON rendering of that form (kind/name/assigns/binds…), and the loop
  # then translated the JSON BACK into source terms — two spellings of one
  # idea, with the translation layer being where a model's invention could
  # pass every check (an invented key is self-consistent everywhere
  # downstream). Source removes the translation: `spell.run` READS the text
  # (never evaluates it), classifies by head symbol, sanitizes handler bodies
  # to their reply tags, and hands the result to the same `parse`/`parse-view`
  # an author's file takes. Downstream cannot tell the difference, which is
  # the point.
  @run_tool_schema "{\"properties\":{\"rationale\":{\"description\":\"why this change, in one sentence — shown in the chat\",\"type\":\"string\"},\"source\":{\"description\":\"the definition, as beam-lisp source: (defcontract name (assign @x :type init) (on :ev [param] (ok ...) ...) ...) for server-owned state and events, or (defview name (markup (template &shell [...] ...) ...) ...) for markup, style and bindings. A contract declares an event's SHAPE; handler bodies are read for their (ok ...)/(err ...) reply tags and replaced by inert stubs.\",\"type\":\"string\"}},\"required\":[\"source\",\"rationale\"],\"type\":\"object\"}"
  def run_tool do
    %{
      name: @tool_name,
      description:
        "Add a contract or a view to the running machine, written in the same source " <>
          "an author would use. The definition is read (never evaluated), checked against " <>
          "everything registered so far, compiled by verse and checked for dead bindings; " <>
          "a rejection returns the compiler's own diagnostic and the machine is left unchanged.",
      parameters: @run_tool_schema
    }
  end
  # ── lifecycle ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    Spell.init!(["spell.app", "spell.run", "spell.live"])

    state = %{
      machine: seeded_machine(),
      version: 0,
      transcript: [],
      attempts: [],
      last_build: :ok,
      publish: Keyword.get(opts, :publish, true),
      persist: Keyword.get(opts, :persist, persist_default?())
    }

    state = replay_journal(state)

    {:ok, publish(state)}
  end

  # Persistence defaults ON outside test (the repl must remember; that is its
  # point) and OFF in test, where every loop gets a fresh machine and writing
  # spell/state/ would make suites order-dependent. Tests that exercise
  # persistence pass `persist: true` with a tmp `:spell_state_dir`.
  defp persist_default? do
    # ON in releases too: a release has no Mix, and a repl that forgets is
    # the exact thing persistence exists to prevent. Only test turns it off.
    if Code.ensure_loaded?(Mix), do: Mix.env() != :test, else: true
  end

  # Grow the seed machine by the journal: every accepted definition, in
  # acceptance order, through the SAME ladder a live `run` walks — a journal
  # entry that no longer validates (hand-edited, or the ladder got stricter)
  # is REFUSED at boot with a log line, not trusted. The machine stays the
  # last good state; one bad entry cannot strand the boot.
  #
  # Publishing happens ONCE after replay (`init` ends in `publish/1`), not
  # per entry — but rungs 3–4 still run per entry, because a rejected entry
  # must never reach the served page.
  defp replay_journal(%{persist: false} = state), do: state

  defp replay_journal(%{persist: true} = state) do
    # VARS first: the definitions journal can carry a view whose binds call a
    # fn the same session taught the image. Replay order is acceptance order
    # across BOTH journals only by this convention — definitions never define
    # code the vars journal needs (they can't: views are shape, not code).
    Enum.each(BeamLisp.Spell.Persist.vars(), fn source ->
      case fence_eval("(ns spell.vars)\n" <> source) do
        :ok ->
          :ok

        {:error, reason} ->
          require Logger

          Logger.warning(
            "spell.loop: a journaled VAR was refused at boot (fence rung): " <>
              first_line(inspect(reason))
          )
      end
    end)

    machine =
      Enum.reduce(BeamLisp.Spell.Persist.journal(), state.machine, fn source, machine ->
        case run_ladder(source, machine) do
          {:ok, grown, _report, _meta} ->
            grown

          {:error, verdict} ->
            require Logger

            Logger.warning(
              "spell.loop: a journaled definition was refused at boot " <>
                "(#{verdict[:rung]} rung): #{first_line(verdict[:reason])}"
            )

            machine
        end
      end)

    transcript =
      BeamLisp.Spell.Persist.read_transcript()
      |> Enum.map(fn
        %{"role" => role, "content" => content} ->
          # Roles are the loop's own closed set (:user/:model/:system), already
          # interned by this module's code — never model-controlled.
          %{role: String.to_existing_atom(role), content: content}

        other ->
          other
      end)

    # The in-memory transcript is NEWEST-FIRST (say/2 prepends); the file is
    # chronological. Restoring without reversing would make the next say
    # prepend onto a chronological list — every turn after a restart landing
    # BEFORE the restored history.
    %{state | machine: machine, transcript: Enum.reverse(transcript)}
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
  Apply a definition's SOURCE directly, without a model. Returns the verdict map.

  This is the same path a tool call takes; it exists so the loop can be driven
  by a scenario file (`scripts/demo.exs`) and by tests, which is what makes the
  whole thing verifiable without a network.
  """
  def run(server \\ __MODULE__, source, rationale \\ ""),
    do: GenServer.call(server, {:run, source, rationale}, 120_000)

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

  def handle_call({:run, source, rationale}, _from, state) do
    {verdict, state} = apply_source(source, rationale, state)

    if verdict.status == :ok and state.persist do
      # CODE journals apart from DEFINITIONS: different replay rung (fence
      # vs ladder), different file (vars/ vs journal.bl), different order
      # (vars replay first).
      case verdict[:kind] do
        "code" -> BeamLisp.Spell.Persist.append_var(source, rationale)
        _other -> BeamLisp.Spell.Persist.append_definition(source, rationale)
      end
    end

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
      # `:as_written` — these keys are literals in `run_tool/0`, and
      # `spell.provider/tool-decl-json` reads them as keywords.
      Data.to_bl([run_tool()], :as_written)
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
            GenServer.call(server, {:run, parse_arguments(call), parse_rationale(call)}, 300_000)
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
              "✓ " <> definition_summary(call, verdict) <> warning_note(verdict)

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

  defp definition_summary(call, verdict) do
    # kind/name come from the VERDICT, not the call: the ladder read the source
    # and classified it, so what it found is what happened — a tool call's own
    # claims would just be the JSON vocabulary leaking back in.
    kind = Map.get(verdict, :kind, "definition")
    name = Map.get(verdict, :name, "?")
    why = parse_rationale(call)

    "defined #{kind} #{inspect(to_string(name))} — #{why}"
  end

  # What the machine NOTICED about an accepted definition, appended to the ✓.
  #
  # The rungs decide whether a definition is broken; warnings say it is
  # INCOMPLETE, and incomplete definitions are accepted on purpose — a machine
  # that refuses them cannot be grown one definition at a time. But "accepted"
  # was reported as bare success, so the findings existed only in the report
  # nobody reads aloud.
  #
  # Observed live, and visible in `PLAN-027-repl-after.png`: a model redefined
  # chat-view, kept the shell's `{@partial}` and `{@error}` holes, and dropped
  # the `@view` binds that consume them. The machine emitted three
  # `unrendered-assign` warnings, the verdict said "✓ defined view", and the
  # page rendered the literal text `{@partial}` and `{@error}` under the
  # transcript — uninterpolated holes, because nothing bound them.
  #
  # The model could have fixed it in the same turn if it had been told. It was
  # not, so the page shipped with two visible artefacts and the loop reported
  # unqualified success. Naming them turns a silent regression into the next
  # thing the model does — which is what a repl is for.
  #
  # Appended rather than raised, and capped: this is information for the next
  # turn, not a refusal, and a machine mid-growth legitimately carries several.
  defp warning_note(verdict) do
    case verdict[:report] do
      %{"warnings" => [_ | _] = warnings} -> format_warnings(warnings)
      %{warnings: [_ | _] = warnings} -> format_warnings(warnings)
      _ -> ""
    end
  end

  defp format_warnings(warnings) do
    notes =
      warnings
      |> Enum.map(&warning_line/1)
      |> Enum.reject(&(&1 == nil))
      |> Enum.take(6)

    if notes == [], do: "", else: "\n⚠ " <> Enum.join(notes, "; ")
  end

  # Warning maps arrive with string OR atom keys depending on which side of the
  # data boundary they crossed, so both are read rather than assumed.
  defp warning_line(w) do
    get = fn k -> Map.get(w, k) || Map.get(w, to_string(k)) end

    case to_string(get.(:kind)) do
      "unrendered-assign" ->
        "@#{get.(:assign)} is declared but no view renders it — if the markup " <>
          "contains {@#{get.(:assign)}}, it will show as literal text until a bind consumes it"

      "dead-template" ->
        "template &#{get.(:template)} is declared but never invoked"

      "background-without-color" ->
        "#{get.(:selector)} sets a background but no color — the page is dark, " <>
          "so text on that box stays the inherited near-white and may be " <>
          "unreadable. Verse cannot see this: it compares the two only within " <>
          "one rule"

      "template-not-bound" ->
        "template &#{get.(:template)} has no bind connecting it to a binding"

      "" ->
        nil

      other ->
        "#{other}: #{inspect(Map.drop(w, [:kind, "kind"]))}"
    end
  end

  defp first_line(reason) do
    reason
    |> to_string()
    |> String.split("\n")
    |> List.first()
    |> String.slice(0, 300)
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

  defp apply_source(source, _rationale, state) do
    case run_ladder(source, state.machine) do
      {:ok, machine, report, meta} ->
        # Commit, then publish — and if publishing FAILS, say so in the verdict
        # rather than reporting success. The machine still holds the definition
        # (it passed every rung; the failure is downstream, in emitting or
        # building), but a caller told `:ok` while the served page is stale has
        # been lied to, and the next proposal would accumulate on state the user
        # never saw.
        state = publish(%{state | machine: machine})

        case state.last_build do
          :ok ->
            {%{status: :ok, kind: meta.kind, name: meta.name, report: report}, state}

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

  defp run_ladder(source, machine) do
    # The source crosses the language boundary as a VALUE — never printed into
    # a form, never evaluated. Everything the old JSON proposal boundary
    # existed to prevent (model text reaching the evaluator) is prevented by
    # construction: `spell.run/run` READS the text with the reader, classifies
    # by head symbol, and builds the term through the same `parse`/`parse-view`
    # an author's file takes.
    ladder(bl("spell.run", "run", [machine, source]), source)
  end

  # Rungs 1–2 answered; run 3–5 against the CANDIDATE.
  #
  # `candidate` is a local, so a rejected one is unreachable the moment this
  # returns. It was a global var (`(def candidate …)`), which meant a refused
  # proposal stayed addressable from anywhere until the next one overwrote it.
  defp ladder(candidate, source) do
    cond do
      Map.get(candidate, :status) == :rejected ->
        {:error,
         %{
           status: :rejected,
           rung: Map.get(candidate, :rung),
           reason: inspect(Map.get(candidate, :reason))
         }}

      Map.get(candidate, :kind) == "code" ->
        fence_rung(candidate, source)

      true ->
        page_rungs(candidate)
    end
  end

  # Rung 5 — CODE. Compile AND load the definition in a bounded, unlinked,
  # monitored process before the verdict: a syntax error, a crashing macro
  # expansion, or a wedging `(def x (loop …))` initializer dies THERE, and
  # the loop is never blocked past the deadline. The process is separate;
  # the var registry is the IMAGE's, so a successful eval IS the commit to
  # the live image (the journal append happens in `handle_call`, as for
  # every other kind). A failed eval can leave partial vars in the image —
  # the registry is overwritten by the next accepted definition of the same
  # name, and the journal only ever holds ACCEPTED sources, so replay still
  # converges to exactly the accepted set.
  #
  # Task.async is the WRONG primitive here — it links the callee to the
  # caller, so a callee dying before the yield trap window takes the loop
  # down with it (spell.fence documents the same lesson, earned in-repo).
  # spawn + monitor: the death arrives as a message, pattern-matched.
  defp fence_rung(candidate, source) do
    case fence_eval("(ns spell.vars)\n" <> source) do
      :ok ->
        {:ok, Map.get(candidate, :machine), Map.get(candidate, :report),
         %{kind: Map.get(candidate, :kind), name: Map.get(candidate, :name)}}

      {:error, reason} ->
        {:error, %{status: :rejected, rung: :fence, reason: inspect(reason)}}
    end
  end

  defp fence_eval(source) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn -> send(parent, {:fence_result, self(), safe_eval(source)}) end)

    receive do
      {:fence_result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:exit, reason}}
    after
      5_000 ->
        Process.exit(pid, :brutal_kill)
        Process.demonitor(ref, [:flush])
        {:error, {:timeout, 5_000}}
    end
  end

  defp safe_eval(source) do
    BeamLisp.Compiler.eval_string(source)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, value -> {:error, {kind, value}}
  end

  # Rungs 3–4: the page the CANDIDATE would produce.
  defp page_rungs(candidate) do
    machine = Map.get(candidate, :machine)

    # Rungs 3–4 run against the page the CANDIDATE would produce, never the
    # committed one: checking the current page would pass every proposal.
    # The candidate is an `.edn` file in /tmp — NOT the served site dir:
    # writing it there would make serve compile AND RELOAD browsers onto an
    # unverified page. The filesystem is the publish channel; candidates
    # stay off it, checked by the CLI.
    page = Path.join(System.tmp_dir!(), "spell_candidate_#{System.unique_integer([:positive])}.edn")

    try do
      # The bind selectors are handed to rung 4 so it judges OUR page rather
      # than verse's runtime, which also ships `querySelector` calls.
      selectors = Data.from_bl(bl("spell.live", "machine-bind-selectors", [machine]))

      with {:ok, _} <- Spell.Page.emit(machine, page),
           {:ok, _} <- Spell.Verse.verify(page, selectors) do
        {:ok, machine, bl("spell.live", "machine-report", [machine]),
         %{kind: Map.get(candidate, :kind), name: Map.get(candidate, :name)}}
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

  # ── publishing ────────────────────────────────────────────────────────────

  defp publish(%{publish: false} = state), do: %{state | last_build: :ok}

  # Publishing is ONE write plus the verse serve verdict on it. The compile
  # happens inside the long-running serve process (warm registry, no binary
  # spawn); the reload that follows is verse's own websocket, so this function
  # has no reload machinery at all.
  defp publish(state) do
    state = %{state | version: state.version + 1}

    build =
      with {:ok, doc} <- Spell.Page.document(state.machine),
           {:ok, _status} <- Spell.Build.write_and_await(Spell.Build.entry(), doc),
           :ok <- regenerate_host(state.machine) do
        :ok
      end

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
  # That defect — a machine that grows while the browser keeps a stale
  # artifact — was first fixed for the bundle and missed for the host, because
  # the two halves of publishing lived in two files. Both now live here:
  # whatever an accepted definition changes, the loop rebuilds all of it.
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
        # A hole in the SHELL never interpolates.
        #
        # The shell is rendered by the LiveView, server-side, before the bundle
        # hydrates — and only the bundle's templates interpolate `{@name}`. So
        # a hole written into the shell reaches the browser as the literal
        # characters `{@partial}`, sitting in the page forever.
        #
        # Observed live: asked to consume `@partial` and `@error`, a model put
        # `<p class="chat__partial">{@partial}</p>` in the shell AND bound
        # `.chat__partial` with a view bind. The bind was right; the hole was
        # not, and every rung passed it — the markup is well-formed, the class
        # is rendered, the binding is declared. The page shipped showing
        # `{@partial}` and `{@error}` as text.
        #
        # Refused here rather than in a rung because it is a fact about how the
        # shell is HOSTED, which is exactly what this function knows and the
        # rungs do not. The seed's shell has no holes, so this cannot fire on
        # anything that was already working.
        case Regex.scan(~r/\{@[\w.]+\}/, shell) do
          [] ->
            write_host(shell)

          holes ->
            {:error,
             "the shell contains #{Enum.map_join(Enum.uniq(holes), ", ", &List.first/1)} — " <>
               "the shell is rendered server-side, where holes are NOT interpolated, so " <>
               "these would reach the browser as literal text. Put an empty element in " <>
               "the shell and bind a template to it instead."}
        end
    end
  end

  defp write_host(shell) do
    source =
      bl("spell.contract", "elixir-module", [
        BeamLisp.Env.fetch!("spell.seed", "contract-term"),
        BeamLisp.Env.fetch!("spell.seed", "module"),
        shell
      ])

    path = Path.join(gen_dir(), "chat_live.ex")
    File.mkdir_p!(gen_dir())
    File.write!(path, source)

    # Compiling REPLACES the running module in the code server, which is the
    # whole point: the next request renders the new shell. Warnings are
    # silenced because regenerating an existing module legitimately redefines
    # it, and that warning on every accepted definition would train the reader
    # to ignore the log.
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

  @doc "Where the generated server half is written."
  def gen_dir, do: Application.get_env(:beam_lisp, :spell_gen_dir, "spell/gen")

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
  it is verse's dev websocket announcing Reload after the recompile. But a
  reload remounts the LiveView, and `mount` seeds from the contract's DECLARED
  INITIALS — an empty transcript. So asking for a clock worked, the page
  rebuilt, and the conversation that asked for it disappeared. Observed in a
  browser: the user sees their message vanish at the exact moment the thing
  they asked for arrives, which reads as the send having failed.

  The loop already holds the transcript, because it is the thing that survives
  a page. Seeding from it is what makes the reload invisible.

  Only user and model turns: `:system` notes are for the report and the
  console, not for a chat bubble. (Verdicts ARE recorded as `:model` turns —
  see `handle_tool_calls` — because a refusal must survive the reload.)
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

  defp say(%{persist: true} = state, role, content) do
    state = %{state | transcript: [%{role: role, content: content} | state.transcript]}

    # The snapshot is display state for a restarted page: chronological, and
    # through `Data.from_bl` because content may carry keywords (a verdict's
    # :rejected) that JSON has no spelling for.
    state.transcript
    |> Enum.reverse()
    |> Enum.map(&Data.from_bl/1)
    |> BeamLisp.Spell.Persist.write_transcript()

    state
  end

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

  # Tool-call arguments: the tool is JSON because the PROVIDER's tool-call
  # channel is, but the payload is now just two strings — `source` and
  # `rationale` — so there is no keyword conversion left to do. An
  # undecodable payload becomes an empty source, which rung 1 refuses with a
  # reason rather than a crash.
  defp parse_arguments(%{"arguments" => args}) when is_binary(args) do
    case JSON.decode(args) do
      {:ok, %{"source" => source}} when is_binary(source) -> source
      {:ok, other} -> "undecodable tool call: " <> inspect(other)
      {:error, _} -> "undecodable tool call: " <> args
    end
  end

  defp parse_arguments(other), do: "undecodable tool call: " <> inspect(other)

  defp parse_rationale(%{"arguments" => args}) when is_binary(args) do
    case JSON.decode(args) do
      {:ok, %{"rationale" => rationale}} when is_binary(rationale) -> rationale
      _ -> ""
    end
  end

  defp parse_rationale(_other), do: ""
end
