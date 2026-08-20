defmodule BeamLisp.Spell.Server do
  @moduledoc """
  The join between a Phoenix LiveView and the contract that describes it.

  A contract's handler bodies are beam-lisp data; `spell.server` walks them and
  answers with a reply, new assigns and requested effects. This module is the
  only thing between that answer and a socket:

      handle_event("send", payload, socket)
        → spell.server/handle          (walks the contract body)
        → apply assigns to the socket  (the bridge pushes the diff)
        → push declared effects        (Spacetime.LiveView.push_event)
        → start a model turn if the body asked for one  (the loop streams it back)
        → {:reply, %{tag:, reply:}, socket}

  Nothing here knows what a chat is. Every name — `send`, `messages`, `token` —
  arrives from the contract, which is why one generated LiveView per contract
  needs no code of its own beyond the delegating heads.

  ## A beam-lisp fn is an Elixir fn

  `spell.server/handle` is reached by FETCHING it and calling it:

      {:ok, handle} = BeamLisp.Env.fetch("spell.server", "handle")
      handle.(contract, event, payload, assigns)

  This module used to print its arguments as beam-lisp source and hand the text
  to `Compiler.eval_string/1`. Two things were wrong with that, and the second
  is why it is gone:

    * **it was a leak.** `eval_string` compiles a FRESH BEAM module per call.
      Modules are reclaimable; the atoms their names intern are not, and a full
      atom table aborts the VM uncatchably (`BeamLisp.AtomGuard`). Measured on
      the seed contract: ONE event cost +6 modules and +153 atoms, and
      `info/3` runs once per STREAMED TOKEN — so a single long answer left
      hundreds of modules behind, permanently, on the path a user drives with
      their keyboard.
    * **it made wire data dangerous.** Printing means a map KEY can close the
      call and open a new form; `BeamLisp.Spell.Data` records the payload that
      did exactly that. Whitelisting keys made that payload safe without making
      printing safe — the shape of every escaping bug ever written.

  Converting instead of printing removes both at once: there is no source for a
  key to break out of, and no compilation to leak.

  ### What the fn value preserves

  `eval_string` evaluated in the CALLING process, and this design leans on it:
  the walk records `(ask! text)` rather than performing it, and the caller — the
  LiveView pid — performs it, so `(erlang/self)` there is the process a streamed
  answer must return to. Applying a fn value directly keeps that property for
  the same reason it keeps every other one: nothing about it moves processes.
  Asserted in `allocation_test.exs` rather than assumed.
  """

  alias BeamLisp.Spell.Data

  # Where each contract lives, as a RESOLVER — a zero-arity function answering
  # the current term. Registered at boot by whoever generated the LiveView (see
  # scripts/serve_live.exs), so this module never guesses which term a generated
  # module refers to. persistent_term because it is written once and read on
  # every event: the read is free, the write cost is irrelevant at boot.
  @registry {__MODULE__, :contracts}

  @doc """
  Point a contract name at the term it names.

      register("chat-live", fn -> BeamLisp.Env.fetch!("spell.seed", "contract-term") end)
      register("chat-live", "spell.seed/contract-term")   # convenience

  The generated `SpellWeb.ChatLive` carries `@contract "chat-live"` and nothing
  else; this is what turns that name into the live term.

  A FUNCTION rather than a value, so the machine can grow underneath it: point
  the name at the loop's own lookup and every later event sees the current
  definition without re-registering. That was the whole reason the old registry
  held a beam-lisp EXPRESSION — a resolver keeps the late binding and drops the
  evaluation.

  The string form is accepted because it reads well at a call site and is what
  every existing caller passes. It resolves `"ns/name"` through
  `BeamLisp.Env.fetch/2` ONCE PER CALL, which is a map lookup, not a compile.
  """
  def register(name, resolver) when is_binary(name) and is_function(resolver, 0) do
    current = :persistent_term.get(@registry, %{})
    :persistent_term.put(@registry, Map.put(current, name, resolver))
    :ok
  end

  def register(name, expression) when is_binary(name) and is_binary(expression) do
    case String.split(expression, "/", parts: 2) do
      [ns, var] ->
        register(name, fn -> BeamLisp.Env.fetch!(ns, var) end)

      _ ->
        raise ArgumentError,
              "a contract expression must be \"namespace/var\", got #{inspect(expression)}. " <>
                "Pass a zero-arity function for anything else — this registry no longer " <>
                "evaluates beam-lisp source."
    end
  end

  @doc """
  The term registered as `name`.

  Resolution order:

    1. the explicit registry (`register/2`) — tests and scripts pin a resolver
    2. the LOOP's live machine, looked up by contract name — the default, so a
       contract the machine ACCEPTED is resolvable the moment it lands, with
       no registration step to forget

  Raises naming what is registered when neither answers.
  """
  def contract_term(name) do
    registry = :persistent_term.get(@registry, %{})

    case Map.fetch(registry, name) do
      {:ok, resolver} ->
        resolver.()

      :error ->
        case machine_contract(name) do
          nil ->
            raise ArgumentError,
                  "no contract named #{inspect(name)} — not in the registry " <>
                    "(registered: #{inspect(Map.keys(registry))}) and not in the loop's " <>
                    "machine (or no loop is running)."

          term ->
            term
        end
    end
  end

  # The machine's contract named `name`, or nil. Asks the process that OWNS the
  # machine — `Spell.Loop.machine/0` is the one way to ask, and the lookup is
  # per call so a redefinition accepted a second ago is the term answered.
  # Never called from the loop process itself (its own callers are LiveViews);
  # a self-call would deadlock the GenServer.
  defp machine_contract(name) do
    if loop_running?() do
      contracts = apply_bl("spell.machine", "contracts", [BeamLisp.Spell.Loop.machine()])

      contracts
      |> BeamLisp.Vector.to_list()
      |> Enum.find(fn c -> to_string(Map.get(c, :name)) == name end)
    end
  rescue
    _ -> nil
  end

  # ── LiveView callbacks, one per generated head ─────────────────────────────

  # Single-contract form retained for a one-contract caller; the machine's
  # generated module always passes the LIST.
  def mount(socket, contract) when is_binary(contract), do: mount(socket, [contract])

  @doc """
  `mount/3`'s body, over EVERY contract the machine holds.

  The seed travels as ordinary assigns, so the bridge's after-render reconciler
  pushes it as the first `st-set` diff on the connected mount. There is no
  separate seeding path — which is what the static host page had to fake with a
  retrying JS timer, and why its transcript could arrive as `null`.

  The generated host is one LiveView serving the whole machine
  (`spell.contract/machine-module`), so mount seeds each contract's declared
  initials, overlays the loop's transcript, and then runs each contract's
  declared `:mount-event` — an ordinary no-param event (the live-state
  contract's `:refresh`), run through the SAME `spell.server/handle` walk a
  page event takes. That is how `@vars` is populated before the first render:
  the state a page opens with is computed by the contract's own handler, not
  by a seeding path that could disagree with it. A remount re-runs it, and
  the browser remounts when the machine grows — so first load and growth are
  one path.
  """
  def mount(socket, contracts) when is_list(contracts) do
    terms = Enum.map(contracts, &contract_term/1)

    seed =
      terms
      |> Enum.map(&Data.from_bl(call("seed-assigns", [&1, %{}])))
      |> Enum.reduce(%{}, &Map.merge/2)

    socket = assign_all(socket, Map.merge(seed, restored_messages()))

    Enum.reduce(terms, {:ok, socket}, fn term, {:ok, socket} ->
      case call("mount-event", [term]) do
        nil -> {:ok, socket}
        event -> {:ok, run_mount_event(socket, term, to_string(event))}
      end
    end)
  end

  # A mount event is just the contract's handler, run once with an empty
  # payload. It must not `ask!` — a mount is not a turn — but nothing forbids
  # it structurally; the contract author owns that choice.
  defp run_mount_event(socket, term, event_name) do
    result =
      Data.from_bl(
        call("handle", [
          term,
          event_name,
          Data.to_bl(%{}, :all_strings),
          Data.to_bl(current_assigns(socket), :all_strings)
        ])
      )

    apply_result(socket, nil, result)
  end

  # The transcript merge in `mount/2` deserves its history kept: the page
  # reloads itself when the machine grows — that is the point — and a reload
  # remounts this LiveView, which seeds from the declarations: an empty
  # conversation. So asking for a clock worked, the page rebuilt, and the
  # message that asked for it vanished at the exact moment the clock appeared.
  # Observed in a browser; it reads as the send having failed. The loop holds
  # the transcript because it is the thing that outlives a page, and merging
  # it over the seed is what makes the reload invisible. Only when a loop is
  # running: without one there is no conversation to restore, and the
  # declared empty transcript is correct.

  defp restored_messages do
    if loop_running?() do
      case BeamLisp.Spell.Loop.transcript_messages() do
        [] -> %{}
        messages -> %{"messages" => messages}
      end
    else
      %{}
    end
  rescue
    # A loop that is starting, stopping or wedged must not stop a page from
    # mounting: an empty transcript is a worse page, a failed mount is no page.
    _ -> %{}
  end

  @doc """
  `handle_event/3`'s body: walk the contract's handler and answer the page.

  The reply envelope is the bridge's: `%{tag:, reply:}`, where `tag` is one of
  the tags `spell.seam/reply-tags` enumerated from this same body — so the arms
  the page decodes with cannot disagree with the tags the server can send.
  """
  def event(socket, contract, event_name, payload) do
    result =
      Data.from_bl(
        call("handle", [
          contract_term(contract),
          to_string(event_name),
          # `:all_strings` on BOTH — `spell.server/bind-params` looks a
          # parameter up by string first and by keyword second, and the assigns
          # map is keyed by the contract's own declared names, which the
          # interpreter also reads as strings. Converting either to keywords
          # would intern whatever the browser sent.
          Data.to_bl(payload, :all_strings),
          Data.to_bl(current_assigns(socket), :all_strings)
        ])
      )

    case Map.get(result, "status") do
      "no-handler" ->
        # A page firing an event that reaches nothing is FUP-143 hole #1, and
        # `spell.seam/handler-for` deliberately reports it rather than
        # defaulting. Answer with the error tag so the page's `_` arm shows
        # something, and say which event — a silent nil would leave the signal
        # pending forever.
        {:reply, %{tag: "err", reply: "no handler for #{event_name}"}, socket}

      _ ->
        socket = apply_result(socket, contract, result)

        case Map.get(result, "reply") do
          nil -> {:noreply, socket}
          reply -> {:reply, %{tag: Map.get(reply, "tag"), reply: Map.get(reply, "value")}, socket}
        end
    end
  end

  # Single-contract form; the machine's generated module always passes the LIST.
  def info(socket, contract, message) when is_binary(contract),
    do: info(socket, [contract], message)

  @doc """
  `handle_info/2`'s body, fanned out over EVERY contract the machine holds.

  One LiveView serves the machine, so a server-internal message is offered to
  each contract in registration order; a contract whose `on-info` clauses do
  not match answers "unmatched" and leaves the socket untouched. Two contracts
  MAY both match one message — each applies its own clause, in order, later
  contracts seeing earlier ones' assigns.

  Provider tokens arrive here. They need no second transport precisely because
  a streamed token is an ordinary BEAM message, decoded by the same contract
  that decodes the page's events.
  """
  def info(socket, contracts, message) when is_list(contracts) do
    {socket, matched?} =
      Enum.reduce(contracts, {socket, false}, fn contract, {socket, matched?} ->
        result =
          Data.from_bl(
            call("handle-info", [
              contract_term(contract),
              Data.to_bl(message_vector(message), :all_strings),
              Data.to_bl(current_assigns(socket), :all_strings)
            ])
          )

        case Map.get(result, "status") do
          "unmatched" -> {socket, matched?}
          _ -> {apply_result(socket, contract, result), true}
        end
      end)

    unless matched? do
      # A message NO contract describes must not be silent either — this is how
      # a protocol drift is noticed.
      require Logger
      Logger.debug("spell.server: no on-info clause in any contract for #{inspect(message)}")
    end

    {:noreply, socket}
  end

  # ── applying an interpreter answer to a socket ─────────────────────────────

  defp apply_result(socket, contract, result) do
    socket
    |> assign_all(Map.get(result, "assigns", %{}))
    |> push_all(Map.get(result, "pushes", []))
    |> maybe_ask(contract, Map.get(result, "ask"))
  end

  # Assign names are turned into atoms, which is safe BECAUSE the set is closed:
  # they are the contract's declared assigns, printed by our own emitter. An
  # unbounded String.to_atom over wire data is how an atom table fills; this one
  # ranges over a handful of names fixed at definition time.
  # is_map-ok: `plain/1` has already unwrapped Vector and every other beam-lisp
  # struct, so a struct reaching here would be a bug in that conversion rather
  # than an assign shape to accept quietly.
  defp assign_all(socket, assigns) when is_map(assigns) do
    Enum.reduce(assigns, socket, fn {name, value}, acc ->
      Phoenix.Component.assign(acc, String.to_atom(to_string(name)), value)
    end)
  end

  defp push_all(socket, pushes) when is_list(pushes) do
    Enum.reduce(pushes, socket, fn push, acc ->
      Spacetime.LiveView.push_event(acc, Map.get(push, "name"), Map.get(push, "payload"))
    end)
  end

  defp push_all(socket, _), do: socket

  # `(ask! text)` recorded a request; performing it is the caller's job because
  # the caller is the process the answer must come back to.
  defp maybe_ask(socket, _contract, nil), do: socket

  defp maybe_ask(socket, _contract, text) do
    # THE JOIN. `(ask! text)` goes to the LOOP — the process that owns the
    # machine, offers `run`, and walks the rungs. The chat IS the product:
    # the page talks to a real model, the model proposes source, the ladder
    # judges, the page reloads. (W5 tried external-only via /spell/mcp; that
    # face remains for agents, but the main interaction is here.)
    #
    # There is deliberately NO no-loop fallback. If the loop is not running
    # that is a deployment bug, and it fails LOUDLY here rather than as a
    # page that politely does nothing.
    #
    # The messages come back to `self()`, this LiveView's pid, and every one
    # of them is already described by the contract's `on-info` clauses: a
    # verdict arrives the same way a token does.
    true = loop_running?()
    BeamLisp.Spell.Loop.ask_async(BeamLisp.Spell.Loop, text, self())

    socket
  end

  defp loop_running?, do: is_pid(Process.whereis(BeamLisp.Spell.Loop))

  # ── the two boundaries ─────────────────────────────────────────────────────

  defp current_assigns(socket) do
    socket.assigns
    |> Map.drop([:__changed__, :flash, :live_action])
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  # An info message arrives as an Erlang tuple; the contract's patterns are
  # vectors. One shape crosses, and it is the contract's.
  defp message_vector(message) when is_tuple(message), do: Tuple.to_list(message)
  defp message_vector(message) when is_list(message), do: message
  defp message_vector(message), do: [message]

  # ── calling into beam-lisp ─────────────────────────────────────────────────

  # `spell.server/<name>` applied to already-converted arguments.
  #
  # Fetched per call rather than cached in a module attribute, and that is
  # deliberate: `BeamLisp.Env` is where a REDEFINED var lands, so a cached
  # capture would keep running the definition that existed at boot. Hot code
  # replacement is the point of this whole system — caching the lookup would
  # quietly opt this module out of it. The lookup is an ETS read (~1 µs against
  # a 118 µs walk).
  defp call(name, args), do: apply_bl("spell.server", name, args)

  defp apply_bl(ns, name, args) do
    fun = BeamLisp.Env.fetch!(ns, name)

    unless is_function(fun, length(args)) do
      raise ArgumentError,
            "#{ns}/#{name} is not a function of #{length(args)} argument(s) — got #{inspect(fun)}"
    end

    apply(fun, args)
  end
end
