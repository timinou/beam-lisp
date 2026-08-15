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

  alias BeamLisp.{Compiler, Spell}

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

    # The seed is bound as a var so every later emit can name it; the machine
    # itself is threaded as a value.
    Compiler.eval_string("""
    (def live-machine
      (spell.live/seeded (spell.machine/empty-machine)
                         spell.seed/contract-term
                         spell.seed/view-term))
    """)

    state = %{
      out: out,
      version: 0,
      transcript: [],
      attempts: [],
      last_build: :ok,
      publish: Keyword.get(opts, :publish, true)
    }

    {:ok, publish(state)}
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

  # ── handlers ──────────────────────────────────────────────────────────────

  @impl true
  def handle_call(:state, _from, state), do: {:reply, snapshot(state), state}

  def handle_call({:define, proposal}, _from, state) do
    {verdict, state} = apply_proposal(proposal, state)
    {:reply, verdict, state}
  end

  def handle_call(:rebuild, _from, state) do
    {:reply, :ok, publish(state)}
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
  defp turn(state, _text, 0) do
    {%{status: :exhausted, attempts: @max_attempts}, say(state, :system, "no definition accepted after #{@max_attempts} attempts — the machine is unchanged")}
  end

  defp turn(state, text, attempts_left) do
    cfg_src = """
    (assoc (spell.provider/from-env) :tools
      [{:name #{inspect(@tool_name)}
        :description #{inspect(define_tool().description)}
        :parameters #{inspect(@define_tool_schema)}}])
    """

    messages = provider_messages(state, text)

    turn_result =
      Compiler.eval_string("""
      (spell.provider/ask-turn #{cfg_src} #{messages})
      """)

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
    case run_ladder(proposal) do
      {:ok, report} ->
        # Commit, then publish — and if publishing FAILS, say so in the verdict
        # rather than reporting success. The machine still holds the definition
        # (it passed every rung; the failure is downstream, in emitting or
        # building), but a caller told `:ok` while the served page is stale has
        # been lied to, and the next proposal would accumulate on state the user
        # never saw.
        Compiler.eval_string("(def live-machine candidate-machine)")
        state = publish(state)

        case state.last_build do
          :ok ->
            {%{status: :ok, report: report}, state}

          {:error, reason} ->
            {%{status: :published_stale, rung: :publish, reason: reason, report: report}, state}
        end

      {:error, verdict} ->
        # The candidate is discarded by simply not binding it: `live-machine`
        # still names the value it named before. Rollback is the absence of a
        # write, which is the only kind that cannot half-happen.
        {verdict, state}
    end
  end

  defp run_ladder(proposal) do
    # Printing happens BEFORE anything is evaluated, and it refuses a proposal it
    # cannot print safely (see `to_bl/1`). A refusal here is a schema rejection,
    # not a crash: a model probing the boundary should get the same bounded
    # answer as one that simply mistyped a field.
    case safe_to_bl(proposal) do
      {:error, reason} ->
        {:error, %{status: :rejected, rung: :schema, reason: reason}}

      {:ok, src} ->
        Compiler.eval_string("(def candidate (spell.define/define live-machine #{src}))")
        ladder_after_build()
    end
  end

  defp safe_to_bl(proposal) do
    {:ok, to_bl(proposal)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  defp ladder_after_build do
    status = Compiler.eval_string("(get candidate :status)")

    if status == :rejected do
      {:error,
       %{
         status: :rejected,
         rung: Compiler.eval_string("(get candidate :rung)"),
         reason: inspect(Compiler.eval_string("(get candidate :reason)"))
       }}
    else
      Compiler.eval_string("(def candidate-machine (get candidate :machine))")

      # Rungs 3–4 run against the page the CANDIDATE would produce, never the
      # committed one: checking the current page would pass every proposal.
      page = Path.join(System.tmp_dir!(), "spell_candidate_#{System.unique_integer([:positive])}.st")

      try do
        # The bind selectors are handed to rung 4 so it judges OUR page rather
        # than verse's runtime, which also ships `querySelector` calls.
        selectors = bl_json(Compiler.eval_string("(spell.live/machine-bind-selectors candidate-machine)"))

        with {:ok, _} <- Spell.Page.emit("candidate-machine", page),
             {:ok, _} <- Spell.Verse.verify(page, selectors) do
          {:ok, Compiler.eval_string("(spell.live/machine-report candidate-machine)")}
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
      with {:ok, _} <- Spell.Page.emit("live-machine", page),
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
      machine: bl_json(Compiler.eval_string("(spell.live/machine-report live-machine)"))
    }
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
    history =
      state.transcript
      |> Enum.reverse()
      |> Enum.filter(&(&1.role in [:user, :model]))
      |> Enum.reject(&(&1.role == :user and &1.content == text))
      |> Enum.map(fn %{role: r, content: c} ->
        "{:role #{inspect(to_role(r))} :content #{inspect(to_string(c))}}"
      end)

    "[" <> Enum.join(history ++ ["{:role \"user\" :content #{inspect(text)}}"], " ") <> "]"
  end

  defp to_role(:model), do: "assistant"
  defp to_role(other), do: to_string(other)

  # ── plumbing ──────────────────────────────────────────────────────────────

  defp decode_turn(turn) do
    case bl_json(turn) do
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

  # A beam-lisp value as plain JSON-ish data: vectors become lists, keywords
  # become strings, nested structures recurse.
  defp bl_json(%BeamLisp.Vector{} = v), do: Enum.map(BeamLisp.Vector.to_list(v), &bl_json/1)
  defp bl_json(list) when is_list(list), do: Enum.map(list, &bl_json/1)
  defp bl_json(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom), do: Atom.to_string(atom)

  # is_map-ok: a beam-lisp report is walked structurally here; the Vector clause
  # above takes the one struct kind that reaches this function, and every other
  # value is a plain map from `spell.machine/report`.
  defp bl_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(bl_json(k)), bl_json(v)} end)
  end

  defp bl_json(other), do: other

  # ── the data boundary ─────────────────────────────────────────────────────
  #
  # A proposal as beam-lisp source. THIS IS THE SECURITY BOUNDARY OF THE WHOLE
  # DESIGN: everything here is written by a model, and the result is handed to
  # `Compiler.eval_string/1`.
  #
  # It claimed to be "a printer, not an evaluator" and it was not. Values were
  # escaped through `inspect/1`, but KEYS were concatenated raw after a colon,
  # so a JSON object key could close the call and open a new form. Reproduced
  # by a reviewer and confirmed here — this key:
  #
  #   kind "view"}))\n(def pwned 99)\n(def candidate2 (spell.define/define … {:kind
  #
  # emitted three top-level forms, the middle one arbitrary, and `pwned`
  # evaluated to 99 BEFORE any rung ran. A model could have reached anything
  # the BEAM can reach.
  #
  # The fix is not more escaping. It is a WHITELIST: a key must match
  # `[a-z][a-z0-9-]*` — the shape of every field the tool's schema declares —
  # and anything else is refused before a character is printed. Escaping asks
  # "did I remember every metacharacter?"; a whitelist asks "is this one of the
  # names I expect?", and only the second question has a safe default.

  @key_pattern ~r/\A[a-z][a-z0-9_-]*\z/

  defp to_bl(%_{} = struct) do
    raise ArgumentError,
          "a proposal may only contain JSON data; got the struct #{inspect(struct.__struct__)}"
  end

  defp to_bl(value) when is_map(value) and not is_struct(value) do
    "{" <>
      Enum.map_join(value, " ", fn {k, v} ->
        key = to_string(k)

        unless Regex.match?(@key_pattern, key) do
          raise ArgumentError,
                "a proposal key must be a plain lowercase name, got #{inspect(key)} " <>
                  "— refusing to print it as source"
        end

        ":#{key} #{to_bl(v)}"
      end) <> "}"
  end

  defp to_bl(value) when is_list(value), do: "[" <> Enum.map_join(value, " ", &to_bl/1) <> "]"
  defp to_bl(value) when is_binary(value), do: inspect(value)
  defp to_bl(value) when is_number(value), do: to_string(value)
  defp to_bl(true), do: "true"
  defp to_bl(false), do: "false"
  defp to_bl(nil), do: "nil"
  defp to_bl(value) when is_atom(value), do: inspect(to_string(value))
end
