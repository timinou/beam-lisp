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
        → start a provider turn if the body asked for one
        → {:reply, %{tag:, reply:}, socket}

  Nothing here knows what a chat is. Every name — `send`, `messages`, `token` —
  arrives from the contract, which is why one generated LiveView per contract
  needs no code of its own beyond the delegating heads.

  ## Why `eval_string` rather than `apply/3`

  beam-lisp namespaces are interpreted through `BeamLisp.Env`, not compiled to
  BEAM modules, so there is no `:"spell.server".handle/4` to call. Every call
  therefore prints its arguments as beam-lisp source. That has one property this
  design leans on: **`eval_string` evaluates in the CALLING process**, so
  `(erlang/self)` inside these calls is the LiveView's own pid — which is how a
  streamed provider answer finds its way back to the page without this module
  ever handling a pid.

  ## The printing boundary

  Values printed into source come from two places: the contract (ours) and the
  wire (the browser's). `BeamLisp.Spell.Live` records what happened when a
  printer trusted the second kind — a crafted map KEY closed the form and opened
  a new one, and arbitrary beam-lisp evaluated before any check ran. The fix
  there and here is the same and is not escaping: a key must match a plain
  lowercase name, or it is refused before a character is printed.
  """

  alias BeamLisp.Compiler

  @key_pattern ~r/\A[a-zA-Z][a-zA-Z0-9_-]*\z/

  # Where each contract lives, as a beam-lisp EXPRESSION. Registered at boot by
  # whoever generated the LiveView (see scripts/serve_live.exs), so this module
  # never guesses which term a generated module refers to. persistent_term
  # because it is written once and read on every event: the read is free, the
  # write cost is irrelevant at boot.
  @registry {__MODULE__, :contracts}

  @doc """
  Point a contract name at the beam-lisp expression that evaluates to its term.

  `register("chat-live", "spell.seed/contract-term")` — the generated
  `SpellWeb.ChatLive` carries `@contract "chat-live"` and nothing else; this is
  what turns that name into the live term. An expression rather than a value so
  the machine can grow underneath it: point the name at `live-machine`'s lookup
  and every later event sees the current definition.
  """
  def register(name, expression) when is_binary(name) and is_binary(expression) do
    current = :persistent_term.get(@registry, %{})
    :persistent_term.put(@registry, Map.put(current, name, expression))
    :ok
  end

  @doc "The registered expression for `name`, or raise naming what is registered."
  def contract_expr(name) do
    registry = :persistent_term.get(@registry, %{})

    case Map.fetch(registry, name) do
      {:ok, expr} ->
        expr

      :error ->
        raise ArgumentError,
              "no contract registered as #{inspect(name)} " <>
                "(registered: #{inspect(Map.keys(registry))}). " <>
                "Call BeamLisp.Spell.Server.register/2 before serving."
    end
  end

  # ── LiveView callbacks, one per generated head ─────────────────────────────

  @doc """
  `mount/3`'s body: seed the socket with the contract's declared initials.

  The seed travels as ordinary assigns, so the bridge's after-render reconciler
  pushes it as the first `st-set` diff on the connected mount. There is no
  separate seeding path — which is what the static host page had to fake with a
  retrying JS timer, and why its transcript could arrive as `null`.
  """
  def mount(socket, contract) do
    seed = bl(~s|(spell.server/seed-assigns #{contract_expr(contract)} {})|)
    {:ok, assign_all(socket, seed)}
  end

  @doc """
  `handle_event/3`'s body: walk the contract's handler and answer the page.

  The reply envelope is the bridge's: `%{tag:, reply:}`, where `tag` is one of
  the tags `spell.seam/reply-tags` enumerated from this same body — so the arms
  the page decodes with cannot disagree with the tags the server can send.
  """
  def event(socket, contract, event_name, payload) do
    result =
      bl("""
      (spell.server/handle #{contract_expr(contract)} #{inspect(event_name)}
                           #{to_bl(payload)} #{to_bl(current_assigns(socket))})
      """)

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

  @doc """
  `handle_info/2`'s body: route a server-internal message through the contract's
  `on-info` clauses.

  Provider tokens arrive here. They need no second transport precisely because
  a streamed token is an ordinary BEAM message, decoded by the same contract
  that decodes the page's events.
  """
  def info(socket, contract, message) do
    result =
      bl("""
      (spell.server/handle-info #{contract_expr(contract)}
                                #{to_bl(message_vector(message))}
                                #{to_bl(current_assigns(socket))})
      """)

    case Map.get(result, "status") do
      "unmatched" ->
        # Keep the assigns and say so once. A message the contract does not
        # describe must not change state, and must not be silent either — this
        # is how a protocol drift is noticed.
        require Logger
        Logger.debug("spell.server: no on-info clause for #{inspect(message)}")
        {:noreply, socket}

      _ ->
        {:noreply, apply_result(socket, contract, result)}
    end
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
  # the caller is the process the answer must come back to. `stream-async` spawns
  # UNLINKED (its own doc explains why: a provider that dies mid-answer must not
  # take the page with it) and sends `[:delta id chunk]`, `[:done id]` or
  # `[:failed id why]` — the exact messages the contract's `on-info` clauses
  # already describe.
  defp maybe_ask(socket, _contract, nil), do: socket

  defp maybe_ask(socket, _contract, text) do
    id = "m#{System.unique_integer([:positive])}"

    bl("""
    (spell.provider/stream-async (spell.provider/from-env)
                                 #{provider_messages(socket, text)}
                                 (erlang/self)
                                 #{inspect(id)})
    """)

    socket
  end

  # The conversation as the provider wants it. Roles are translated at this
  # boundary and nowhere else: the contract says "model" (what the page shows),
  # every OpenAI-shaped API says "assistant".
  defp provider_messages(socket, text) do
    history =
      socket.assigns
      |> Map.get(:messages, [])
      |> Enum.map(fn m ->
        role = if to_string(Map.get(m, "role", "user")) == "model", do: "assistant", else: "user"
        content = to_string(Map.get(m, "text", ""))
        {role, content}
      end)

    # The user's own turn is already in `messages` (the handler appended it
    # before asking), so it is NOT added again here — doing so sent the last
    # message twice, which a model reads as the user repeating themselves.
    history =
      if List.last(history) == {"user", to_string(text)},
        do: history,
        else: history ++ [{"user", to_string(text)}]

    "[" <>
      Enum.map_join(history, " ", fn {role, content} ->
        "{:role #{inspect(role)} :content #{inspect(content)}}"
      end) <> "]"
  end

  # ── the two boundaries ─────────────────────────────────────────────────────

  defp current_assigns(socket) do
    socket.assigns
    |> Map.drop([:__changed__, :flash, :live_action])
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  # A provider message is an Erlang tuple; the contract's patterns are vectors.
  # One shape crosses, and it is the contract's.
  defp message_vector(message) when is_tuple(message), do: Tuple.to_list(message)
  defp message_vector(message) when is_list(message), do: message
  defp message_vector(message), do: [message]

  # beam-lisp source for a plain value. See the module doc: KEYS are whitelisted
  # rather than escaped, because escaping asks "did I remember every
  # metacharacter?" and a whitelist asks "is this one of the names I expect?".
  defp to_bl(%_{} = struct),
    do: raise(ArgumentError, "cannot print the struct #{inspect(struct.__struct__)} as beam-lisp")

  # is_map-ok: the struct clause above this one rejects every struct by name
  # BEFORE this clause is reached, so "any map" here means "a plain map" — the
  # only shape that may be printed as beam-lisp source.
  defp to_bl(value) when is_map(value) do
    "{" <>
      Enum.map_join(value, " ", fn {k, v} ->
        key = to_string(k)

        unless Regex.match?(@key_pattern, key) do
          raise ArgumentError,
                "refusing to print #{inspect(key)} as a beam-lisp map key — " <>
                  "keys crossing this boundary must be plain names"
        end

        "#{inspect(key)} #{to_bl(v)}"
      end) <> "}"
  end

  defp to_bl(value) when is_list(value), do: "[" <> Enum.map_join(value, " ", &to_bl/1) <> "]"
  defp to_bl(value) when is_binary(value), do: inspect(value)
  defp to_bl(value) when is_number(value), do: to_string(value)
  defp to_bl(true), do: "true"
  defp to_bl(false), do: "false"
  defp to_bl(nil), do: "nil"
  defp to_bl(value) when is_atom(value), do: ":#{value}"

  # An interpreter answer as plain data: vectors become lists, keywords become
  # strings. Everything crossing back into a socket assign must survive JSON
  # encoding, because the bridge pushes it to the browser verbatim.
  defp plain(%BeamLisp.Vector{} = v), do: Enum.map(BeamLisp.Vector.to_list(v), &plain/1)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)

  defp plain(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom),
    do: Atom.to_string(atom)

  defp plain(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(plain(k)), plain(v)} end)

  defp plain(other), do: other

  defp bl(source), do: source |> Compiler.eval_string() |> plain()
end
