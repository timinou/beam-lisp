defmodule BeamLisp.Server do
  @moduledoc """
  The runtime side of the `defserver` special form.

  A `defserver` in the compiler lowers to a genuine `:gen_server`
  behaviour module; this module is the machinery those generated
  modules rely on. Nothing here is a lookalike — the generated module
  declares `@behaviour :gen_server`, its callbacks return the exact
  tuples OTP accepts, and it is supervised, inspected and hot-swapped
  exactly like any Erlang/Elixir server.

  The two responsibilities:

    * **module naming** — `(defserver counter …)` in namespace
      `"user"` becomes `BeamLisp.Server.User.Counter`, so the scheme
      is predictable and a supervisor can reference it by name.

    * **return constructors** — the faithful core's ergonomic return
      forms (`(reply v state)`, `(noreply state)`, `(ok state)`,
      `(stop reason state)`…) compile to calls on the fns here. They
      are real beam-lisp multi-arity fns (`$blfn`), so every OTP
      return shape is expressible: plain replies, `:hibernate`, timeouts,
      `{:continue, term}` continuations and `{:stop, …}` exits.
  """

  @doc "The generated module backing `(defserver name …)` in namespace `ns`."
  def module_for(ns, name) do
    segments = (ns <> "." <> name) |> String.split(".") |> Enum.map(&Macro.camelize/1)
    Module.concat([BeamLisp.Server | segments])
  end

  @doc """
  The return constructors bound as locals in every server callback
  body. Each value is a beam-lisp `$blfn` dispatching on arity, so the
  compiler's `RT.invoke/2` call path can invoke it with the callback's
  arguments and get back the exact OTP return tuple:

      ok      → {:ok, s}            {:ok, s, t}          (init)
      reply   → {:reply, r, s}      {:reply, r, s, t}    (handle_call)
      noreply → {:noreply, s}       {:noreply, s, t}     (call/cast/info)
      stop    → {:stop, r}          (init)
                {:stop, r, s}       (cast/info)
                {:stop, r, reply, s}(handle_call)
      ignore      → :ignore         (init)
      hibernate   → :hibernate      (timeout slot)
      continue    → {:continue, t}  (timeout slot)
  """
  def return_constructors do
    %{
      "ok" =>
        {:"$blfn", %{1 => fn s -> {:ok, s} end, 2 => fn s, t -> {:ok, s, t} end}, nil},
      "reply" =>
        {:"$blfn",
         %{
           2 => fn r, s -> {:reply, r, s} end,
           3 => fn r, s, t -> {:reply, r, s, t} end
         }, nil},
      "noreply" =>
        {:"$blfn", %{1 => fn s -> {:noreply, s} end, 2 => fn s, t -> {:noreply, s, t} end},
         nil},
      "stop" =>
        {:"$blfn",
         %{
           1 => fn r -> {:stop, r} end,
           2 => fn r, s -> {:stop, r, s} end,
           3 => fn r, reply, s -> {:stop, r, reply, s} end
         }, nil},
      "ignore" => {:"$blfn", %{0 => fn -> :ignore end}, nil},
      "hibernate" => {:"$blfn", %{0 => fn -> :hibernate end}, nil},
      "continue" => {:"$blfn", %{1 => fn t -> {:continue, t} end}, nil}
    }
  end

  @doc """
  Maps a defserver callback keyword (`"handle-call"`) to the OTP
  callback function name and arity (`{:handle_call, 3}`), together
  with the *shape* of its clause:

    * `:pattern` — clauses carry a message pattern plus a param
      vector: `(handle-call PAT [from state] body…)`. Multiple clauses
      dispatch on `PAT`.
    * `:vector` — clauses carry only a param vector: `(init [arg] …)`.

  `nil` for a name that is not a server callback.
  """
  def callback("init"), do: {:init, 1, :vector}
  def callback("handle-call"), do: {:handle_call, 3, :pattern}
  def callback("handle-cast"), do: {:handle_cast, 2, :pattern}
  def callback("handle-info"), do: {:handle_info, 2, :pattern}
  def callback("handle-continue"), do: {:handle_continue, 2, :vector}
  def callback("terminate"), do: {:terminate, 2, :vector}
  def callback(_), do: nil

  # ── client side ────────────────────────────────────────────────────
  #
  # A server you cannot call is not a server. These wrap `:gen_server`
  # directly rather than reimplementing it: the point of the wave is
  # real OTP, so the client path is real OTP too. `start_link/3` takes
  # beam-lisp option maps (`{:name :counter}`) and translates them to
  # the keyword list OTP expects.

  @doc "Start a supervised server. `mod` is the value bound by `defserver`."
  def start_link(mod), do: start_link(mod, nil, %{})
  def start_link(mod, arg), do: start_link(mod, arg, %{})

  # OTP has no "no name" value: an anonymous server uses the /3 arity,
  # a registered one the /4. Passing [] as a name is an ArgumentError.
  def start_link(mod, arg, opts) do
    case server_name(opts) do
      nil -> :gen_server.start_link(mod, arg, gen_opts(opts))
      name -> :gen_server.start_link(name, mod, arg, gen_opts(opts))
    end
    |> unwrap()
  end

  @doc "Start an unsupervised server."
  def start(mod), do: start(mod, nil, %{})
  def start(mod, arg), do: start(mod, arg, %{})

  def start(mod, arg, opts) do
    case server_name(opts) do
      nil -> :gen_server.start(mod, arg, gen_opts(opts))
      name -> :gen_server.start(name, mod, arg, gen_opts(opts))
    end
    |> unwrap()
  end

  @doc "Synchronous call. Default timeout matches OTP's 5s."
  def call(server, msg), do: :gen_server.call(server, msg)
  def call(server, msg, timeout), do: :gen_server.call(server, msg, timeout)

  @doc "Fire-and-forget cast. Always returns nil, as the reply is the absence of one."
  def cast(server, msg) do
    :gen_server.cast(server, msg)
    nil
  end

  @doc "Stop a server, defaulting to a normal exit."
  def stop(server), do: stop(server, :normal)

  def stop(server, reason) do
    :gen_server.stop(server, reason, :infinity)
    nil
  end

  # `{:ok, pid}` is OTP's shape, but a beam-lisp caller wants the pid —
  # a failed start should raise rather than hand back a tuple that
  # silently fails at the next call site.
  defp unwrap({:ok, pid}), do: pid
  defp unwrap(:ignore), do: nil

  defp unwrap({:error, reason}),
    do: raise(RuntimeError, "server failed to start: #{inspect(reason)}")

  # `{:name :counter}` registers locally; anything else starts anonymous.
  defp server_name(opts) when is_map(opts) do
    case Map.get(opts, :name) do
      nil -> nil
      name when is_atom(name) -> {:local, name}
    end
  end

  defp server_name(_), do: nil

  defp gen_opts(opts) when is_map(opts) do
    case Map.get(opts, :timeout) do
      nil -> []
      t -> [timeout: t]
    end
  end

  defp gen_opts(_), do: []

  @doc "Canonical emission order for generated callbacks (drives adjacency)."
  def callback_order, do: [:init, :handle_call, :handle_cast, :handle_info, :handle_continue, :terminate, :code_change]
end
