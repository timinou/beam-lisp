defmodule BeamLisp.Env do
  @moduledoc """
  The var registry — process-scoped environments with a read-through chain.

  Vars live in a public ETS table. Reads are lock-free and happen in the
  caller's process, which keeps compiled code fast and free of a global
  message bottleneck. Namespace and bootstrap state (small, compile-time
  only) stays in the Agent, which also owns the table.

  Unqualified lookups fall back to `core`, mirroring how jank and
  Clojure refer `clojure.core` into every namespace.

  ## Environments (PLAN-046)

  Every table key carries an environment id as its first element. The id
  comes from the process dictionary (`env_id/0`), defaulting to `:global` —
  the zero env, in which every call behaves exactly as it did before envs
  existed.

  An env created by `fork/1` has a PARENT. Reads walk the chain
  `env → parent → … → :global` and resolve at the first hit; writes always
  land in the current env. A fork therefore sees everything its ancestors
  see (read-through) while nothing it defines leaks sideways or upward
  (shadowing). That pair of properties is what makes a per-test env a
  zero-copy checkout of a warm base image.

  The chain is cached in the process dictionary at bind time
  (`with_env/2`, `bind/1`), so the hot path pays one pdict read per op and
  never talks to the Agent. Fork/destroy/mark are cold ops and do.

  `with_env/2` binds an env for the calling process; `isolated/2` forks,
  binds, and destroys. Binding does NOT cross `spawn`/`Task.async` — see
  `capture/0` and `bind/1` (and note `BeamLisp.Refs.future_exec/1` and
  `BeamLisp.Refs.promise/0` already propagate for you; host code spawning
  around beam-lisp work must capture/bind explicitly).

  `current_ns` is process-local inside a fork (Clojure's thread-local
  `*ns*` semantics): `in_ns/1` writes the pdict, and two processes in the
  same env cannot fight over it. At `:global` it stays Agent-backed, so
  REPL and session behavior are unchanged.
  """

  use Agent

  @table :beam_lisp_vars
  @pdict_env :bl_env
  @pdict_chain :bl_env_chain
  @pdict_ns :bl_ns
  @pdict_caps :bl_caps
  @pdict_heap :bl_max_heap
  @op_table :beam_lisp_ops
  @max_chain_depth 8

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        :ets.new(@table, [:named_table, :public, read_concurrency: true])

        %{
          ns: "user",
          seeded: false,
          loaded: MapSet.new(),
          load_paths: [],
          search_paths: [],
          envs: %{}
        }
      end,
      name: __MODULE__
    )
  end

  # ------------------------------------------------------------------
  # Environments
  # ------------------------------------------------------------------

  @doc "The current process's env id (`:global` when unbound)."
  def env_id, do: Process.get(@pdict_env, :global)

  @doc """
  The read-through chain for the current process, innermost first.

  Cached in the pdict at bind time; a destroyed ancestor simply misses in
  ETS and the walk degrades to the next link, so a stale cached chain is
  never a correctness problem.
  """
  def chain, do: Process.get(@pdict_chain, [:global])

  @doc """
  Create a new env whose reads fall through to `parent` (default: the
  current env). Returns the env id; does NOT bind it — see `with_env/2`.

  Options:

    * `:caps` — the host-interop capability set for the new env: `:all`
      (default) or a list/`MapSet` of Elixir/Erlang modules the env's code
      may call (e.g. `[File, String]`). Attenuation is STRUCTURAL, the
      same monotonic-weakening invariant as Biscuit tokens: the child's
      effective caps are `parent ∩ spec` — a fork can only ever narrow,
      never grant a module the parent did not hold. `:global` holds `:all`.
  """
  def fork(parent \\ env_id(), opts \\ []) do
    id = {:env, make_ref()}
    caps = intersect_caps(caps_of(parent), Keyword.get(opts, :caps, :all))
    # Resource bounds narrow like caps: a child never gets MORE heap than
    # its parent. nil = unbounded (the VM default).
    heap = min_heap(heap_of(parent), Keyword.get(opts, :max_heap_words))

    Agent.update(__MODULE__, fn s ->
      envs = Map.get(s, :envs, %{})
      Map.put(s, :envs, Map.put(envs, id, fresh_env_state(parent, caps, heap)))
    end)

    id
  end

  defp fresh_env_state(parent, caps \\ :all, heap \\ nil),
    do: %{parent: parent, loaded: MapSet.new(), search_paths: [], caps: caps, max_heap: heap}

  defp min_heap(nil, spec), do: spec
  defp min_heap(parent, nil), do: parent
  defp min_heap(parent, spec), do: min(parent, spec)

  @doc "The env's max-heap bound in words (nil = unbounded)."
  def heap_of(:global), do: nil

  def heap_of(env) do
    Agent.get(__MODULE__, fn s ->
      case get_in(s, [:envs, env]) do
        nil -> nil
        %{max_heap: heap} -> heap
      end
    end)
  end

  @doc "This process's max-heap bound in words (nil = unbounded)."
  def max_heap, do: Process.get(@pdict_heap)

  defp intersect_caps(:all, :all), do: :all
  defp intersect_caps(:all, spec), do: MapSet.new(spec)
  defp intersect_caps(set, :all), do: set
  defp intersect_caps(set, spec), do: MapSet.intersection(set, MapSet.new(spec))

  # ------------------------------------------------------------------
  # Capabilities (host-interop rights per env)
  # ------------------------------------------------------------------

  @doc """
  The effective capability set of `env`: `:all` or a `MapSet` of allowed
  modules. `:global` holds `:all`; a forked env's caps were intersected at
  fork time, so this lookup never walks the chain.
  """
  def caps_of(:global), do: :all

  def caps_of(env) do
    Agent.get(__MODULE__, fn s ->
      case get_in(s, [:envs, env]) do
        # Absent from the registry = never forked or already destroyed.
        # Caps are a security boundary: fail CLOSED (no host interop),
        # unlike reads, which degrade past dead envs.
        nil -> MapSet.new()
        %{caps: caps} -> caps
      end
    end)
  end

  @doc "The current process's capability set (`:all` when unbound)."
  def caps, do: Process.get(@pdict_caps, :all)

  @doc """
  Whether the current process's env grants interop to `module`,
  optionally narrowed to `op` (an atom like `:read` — see `op_of/2`).

  Grant shapes in a caps set:

    * `File` (bare module)           → every op of that module
    * `{File, :read}` (module-op)    → only fns the op table maps to :read

  A {module, op} grant for an fn the table does NOT list allows nothing
  extra — unlisted fns of an op-scoped module are denied. Unknown modules
  have no table entry: a bare-module grant still covers them, an op-scoped
  grant denies (fail closed on a grant we cannot interpret).

  The hot path of the capability gate: one pdict read + set membership.
  """
  def caps_allowed?(module, op \\ nil) do
    case caps() do
      :all ->
        true

      set ->
        MapSet.member?(set, module) or
          (not is_nil(op) and MapSet.member?(set, {module, op}))
    end
  end

  @doc """
  The op a module's fn performs, per `op_table/0` — or nil when the table
  doesn't say. Data, not code: extend via `register_op/3`.
  """
  def op_of(module, fun) do
    ensure_op_table()

    case :ets.lookup(@op_table, {module, fun}) do
      [{_, op}] -> op
      [] -> nil
    end
  end

  @doc "Add `{module, fn} → op` to the op table (app-specific modules)."
  def register_op(module, fun, op) when is_atom(op) do
    ensure_op_table()
    :ets.insert(@op_table, {{module, fun}, op})
    :ok
  end

  # The default table: the dangerous-shape modules, read/write/env/exec
  # split. Deliberately small and data-shaped — a deployment audits ONE
  # table, not the compiler.
  @default_ops [
    {File, :read, :read}, {File, :read!, :read}, {File, :exists?, :read},
    {File, :ls, :read}, {File, :ls!, :read}, {File, :stat, :read},
    {File, :cwd, :read}, {File, :cwd!, :read},
    {File, :write, :write}, {File, :write!, :write}, {File, :rm, :write},
    {File, :rm!, :write}, {File, :rm_rf, :write}, {File, :mkdir, :write},
    {File, :mkdir_p, :write}, {File, :cp, :write}, {File, :rename, :write},
    {System, :get_env, :env_read}, {System, :fetch_env, :env_read},
    {System, :put_env, :env_write}, {System, :delete_env, :env_write},
    {System, :cmd, :exec}, {System, :shell, :exec},
    {:os, :cmd, :exec}, {:os, :getenv, :env_read}, {:os, :putenv, :env_write},
    {Code, :eval_string, :eval}, {Code, :eval_quoted, :eval},
    {Code, :compile_string, :eval}, {:erlang, :apply, :eval}
  ]

  defp ensure_op_table do
    case :ets.whereis(@op_table) do
      :undefined ->
        BeamLisp.Loader.Server.run(fn ->
          try do
            :ets.new(@op_table, [:named_table, :public, :set, read_concurrency: true])
          rescue
            ArgumentError -> :ok
          end
        end)

        for {m, f, op} <- @default_ops, do: :ets.insert(@op_table, {{m, f}, op})

      _ ->
        :ok
    end
  end

  @doc """
  Run `fun` with `env` bound in the calling process; restores the previous
  binding (and process-local current-ns) afterwards.
  """
  def with_env(env, fun) do
    fun = as_thunk(fun)
    prev_env = Process.get(@pdict_env)
    prev_chain = Process.get(@pdict_chain)
    prev_ns = Process.get(@pdict_ns)
    prev_caps = Process.get(@pdict_caps)
    prev_heap = Process.get(@pdict_heap)

    Process.put(@pdict_env, env)
    Process.put(@pdict_chain, compute_chain(env))
    Process.put(@pdict_caps, caps_of(env))
    restore_pdict(@pdict_heap, heap_of(env))
    # A fresh env means a fresh `*ns*`: Clojure thread-local semantics.
    Process.delete(@pdict_ns)

    try do
      fun.()
    after
      restore_pdict(@pdict_env, prev_env)
      restore_pdict(@pdict_chain, prev_chain)
      restore_pdict(@pdict_ns, prev_ns)
      restore_pdict(@pdict_caps, prev_caps)
      restore_pdict(@pdict_heap, prev_heap)
    end
  end

  @doc """
  Fork an env (parent: the current env), bind it for `fun`, and destroy it
  afterwards. The one-call shape of "run this in a clean room".
  """
  def isolated(fun), do: isolated(env_id(), fun)

  def isolated(parent, fun) do
    env = fork(parent)

    try do
      with_env(env, fun)
    after
      destroy(env)
    end
  end

  # bl fns are tagged structs, not Elixir fns — normalize any invocable
  # thunk to a zero-arity Elixir fn so `env/with-env` works from bl source
  # without the caller hand-wrapping through RT.invoke.
  defp as_thunk(fun) when is_function(fun, 0), do: fun
  defp as_thunk(fun), do: fn -> BeamLisp.RT.invoke(fun, []) end

  @doc """
  Wrap a one-argument invocable (bl fn or Elixir fn) as an ELIXIR
  arity-1 fn that first binds the CALLER's env, then invokes.

  The Agent-action shape of the propagation rule: `Agent.get_and_update`
  validates `is_function`, and a raw bl fn struct fails that — and even
  past the validation it would resolve its vars (and its interop caps) in
  the AGENT's process at `:global`. Conveyance keeps Clojure-dynamic
  semantics across the process boundary: the action resolves exactly as
  if the caller had run it. Caps re-derive in `bind/1`, so a capped
  caller's rights ride along — the confused-deputy fix (FUP-009).
  """
  def convey(fun) do
    token = capture()
    inner = fn arg -> BeamLisp.RT.invoke(fun, [arg]) end
    fn arg -> bind(token); inner.(arg) end
  end

  @doc """
  Drop every row belonging to `env` and forget its bookkeeping.

  One `select_delete` scan guarded on the key's first element, so it works
  for every key shape without enumerating them. A missed destroy leaks ETS
  rows, never correctness — `chain/0` degrades past dead envs.
  """
  def destroy(env) do
    spec = [
      {{:"$1", :_},
       [{:andalso, {:is_tuple, :"$1"}, {:==, {:element, 1, :"$1"}, {:const, env}}}], [true]}
    ]

    :ets.select_delete(@table, spec)

    Agent.update(__MODULE__, fn s ->
      Map.update(s, :envs, %{}, &Map.delete(&1, env))
    end)

    :ok
  end

  @doc """
  Bind `env` in the calling process without a block form — the harness
  primitive behind `Sandbox.checkout/1`, where teardown is a separate
  `on_exit` rather than a function boundary. Prefer `with_env/2` unless
  you own the process lifetime.
  """
  def attach(env) do
    Process.put(@pdict_env, env)
    Process.put(@pdict_chain, compute_chain(env))
    Process.put(@pdict_caps, caps_of(env))
    restore_pdict(@pdict_heap, heap_of(env))
    Process.delete(@pdict_ns)
    :ok
  end

  @doc """
  Capture the current env binding (id + chain + process-local ns) as an
  opaque token for `bind/1`. Host Elixir code that spawns a process to run
  beam-lisp work should capture before spawning and bind in the child.
  """
  def capture do
    %{
      env: Process.get(@pdict_env),
      chain: Process.get(@pdict_chain),
      ns: Process.get(@pdict_ns),
      caps: Process.get(@pdict_caps),
      max_heap: Process.get(@pdict_heap)
    }
  end

  @doc """
  Install a token from `capture/0` in the calling process.

  Caps are RE-DERIVED from `caps_of(env)`, never taken from the token:
  a token is a value and can be stale (env destroyed → fail closed) or
  smuggled across a boundary — the registry is the only source of truth.
  """
  def bind(%{env: env, chain: chain, ns: ns} = token) do
    restore_pdict(@pdict_env, env)
    restore_pdict(@pdict_chain, chain)
    restore_pdict(@pdict_ns, ns)
    restore_pdict(@pdict_caps, env && caps_of(env))
    restore_pdict(@pdict_heap, Map.get(token, :max_heap))
    :ok
  end

  @doc """
  Debug aid: for each env in the chain and each resolution candidate, show
  whether the var is present. Answers "why did this var resolve?" — the one
  question read-through chains make harder.
  """
  def explain(ns, name) do
    for env <- chain(), {cns, cname} <- candidates(ns, name) do
      %{env: env, ns: cns, name: cname, found: :ets.member(@table, pfx(env, {cns, cname}))}
    end
  end

  defp restore_pdict(key, nil), do: Process.delete(key)
  defp restore_pdict(key, value), do: Process.put(key, value)

  # Walk the env metadata to build the read-through chain. Cold: runs once
  # per bind, not per lookup. Degrades past unknown (destroyed) envs.
  defp compute_chain(env), do: compute_chain(env, @max_chain_depth, [])

  defp compute_chain(:global, _depth, acc), do: Enum.reverse([:global | acc])

  defp compute_chain(_env, 0, acc), do: Enum.reverse([:global | acc])

  defp compute_chain(env, depth, acc) do
    case env_state(env) do
      %{parent: :global} -> Enum.reverse([:global, env | acc])
      %{parent: parent} -> compute_chain(parent, depth - 1, [env | acc])
      nil -> Enum.reverse([:global, env | acc])
    end
  end

  defp env_state(env), do: Agent.get(__MODULE__, &get_in(&1, [:envs, env]))

  defp update_env_state(env, fun) do
    Agent.update(__MODULE__, fn s ->
      envs = Map.get(s, :envs, %{})
      state = Map.get(envs, env, fresh_env_state(:global))
      Map.put(s, :envs, Map.put(envs, env, fun.(state)))
    end)
  end

  # ------------------------------------------------------------------
  # Key plumbing (shared by the registry modules)
  # ------------------------------------------------------------------

  # Prefix an old-shape key with an env id. Atoms (trace state) become
  # `{env, atom}`; tuples gain env as element 0. `:global` rows are exactly
  # the old shape plus one leading element — the format change is total,
  # there is no mixed-mode table.
  @doc false
  def pfx(env, k) when is_tuple(k), do: Tuple.insert_at(k, 0, env)
  @doc false
  def pfx(env, k) when is_atom(k), do: {env, k}

  @doc false
  def key(k), do: pfx(env_id(), k)

  @doc "Chain-walking lookup of an old-shape key: `{:ok, value}` or `:error`."
  def lookup(k) do
    Enum.find_value(chain(), :error, fn env ->
      case :ets.lookup(@table, pfx(env, k)) do
        [{_, value}] -> {:ok, value}
        [] -> nil
      end
    end)
  end

  @doc "Chain-walking membership test of an old-shape key."
  def member?(k), do: Enum.any?(chain(), &:ets.member(@table, pfx(&1, k)))

  @doc "Insert `{key, value}` into the CURRENT env (writes never cross envs)."
  def put_key(k, value) do
    :ets.insert(@table, {key(k), value})
  end

  @doc "Delete an old-shape key from the CURRENT env only."
  def delete_key(k), do: :ets.delete(@table, key(k))

  @doc """
  Chain-walking `:ets.match/2`: the whole-row pattern's key half gets the
  env prefix per chain link, results concatenated innermost-first.
  """
  def match({key_pat, val_pat}) do
    Enum.flat_map(chain(), fn env -> :ets.match(@table, {pfx(env, key_pat), val_pat}) end)
  end

  # Exact-env variants: registries that must NOT read through (the bl test
  # registry — a forked suite runs its own tests, never the base's).

  @doc false
  def lookup_own(k) do
    case :ets.lookup(@table, key(k)) do
      [{_, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @doc false
  def match_own({key_pat, val_pat}), do: :ets.match(@table, {key(key_pat), val_pat})

  @doc false
  def match_delete_own({key_pat, val_pat}), do: :ets.match_delete(@table, {key(key_pat), val_pat})

  # ------------------------------------------------------------------
  # Namespaces and vars
  # ------------------------------------------------------------------

  @doc "The namespace new defs land in."
  def current_ns do
    # pdict FIRST, at every env — `*ns*` is thread-local (Clojure's model).
    # The Agent value is the ambient default for processes that never set
    # one (the REPL's published ns, the live panel's display), NOT the
    # compiling process's state: concurrent `:global` library loads used
    # to share the Agent cell and compiled each other's forms under the
    # wrong namespace (relay.completion's def referencing
    # relay.provider.openai-compat/req-llm-generate, PLAN-047 W1).
    Process.get(@pdict_ns) ||
      case env_id() do
        :global -> Agent.get(__MODULE__, & &1.ns)
        _ -> "user"
      end
  end

  def in_ns(ns) when is_binary(ns) do
    Process.put(@pdict_ns, ns)

    # Mirror to the Agent at :global so unbound observers (REPL display,
    # live panel) see the ambient namespace. Compilation never reads the
    # mirror — pdict wins — so concurrent writers cannot cross-compile.
    if env_id() == :global do
      Agent.update(__MODULE__, &%{&1 | ns: ns})
    end

    :ok
  end

  @doc "Bind `name` to `value` in `ns`. Returns the value, like Clojure's def returns the var root."
  def intern(ns, name, value) do
    put_key({ns, name}, value)
    value
  end

  @doc """
  Resolve `name`, looking in `ns` first, then referred vars, and
  falling back to `core` (mirroring how jank and Clojure refer
  `clojure.core` into every namespace).

  Each candidate pair is tried across the whole env chain before moving to
  the next candidate: an env fully shadows its ancestors, candidate by
  candidate.

  A name containing a `/` is split into `{ns, var}`; if the prefix
  is an alias in `ns`, it resolves to the alias target instead.
  """
  def fetch(ns, name) do
    cands = candidates(ns, name)

    Enum.find_value(chain(), :error, fn env ->
      Enum.find_value(cands, nil, fn key ->
        case :ets.lookup(@table, pfx(env, key)) do
          [{_, value}] -> {:ok, value}
          [] -> nil
        end
      end)
    end)
  end

  # The candidate `{ns, name}` pairs a lookup should try, in order:
  # the namespace itself, then referred vars, then `core` (mirroring
  # how jank and Clojure refer `clojure.core` into every namespace).
  # A name containing a `/` splits into `{ns, var}`; if the prefix
  # is an alias in `ns`, it resolves to the alias target instead. A
  # leading slash (`/`, `/x`) is part of the var name itself.
  defp candidates(ns, name) do
    case String.split(name, "/", parts: 2) do
      ["" | _] ->
        [{ns, name}] ++ refer_candidate(ns, name) ++ [{"core", name}, {"sugar", name}]

      [prefix, var_name] ->
        [{alias_target(ns, prefix) || prefix, var_name}]

      [plain] ->
        [{ns, plain}] ++ refer_candidate(ns, plain) ++ [{"core", plain}, {"sugar", plain}]
    end
  end

  @doc "Record `alias` as shorthand for `target` inside `ns`."
  def add_alias(ns, alias_, target) do
    put_key({:alias, ns, alias_}, target)
    :ok
  end

  @doc "The namespace `alias` points to inside `ns`, if any."
  def alias_target(ns, alias_) do
    case lookup({:alias, ns, alias_}) do
      {:ok, target} -> target
      :error -> nil
    end
  end

  @doc """
  Every public var name interned in `ns` — the UNION over the env chain.

  Backs `(:require [ns :refer :all])`. Private vars are filtered here
  rather than at the refer site, so the blanket form can never smuggle
  in a name that the explicit `:refer […]` form would have refused.
  """
  def public_names(ns) do
    names =
      match({{ns, :"$1"}, :_})
      |> List.flatten()
      |> Enum.uniq()

    Enum.reject(names, fn name -> match?({:ok, %{private: true}}, meta(ns, name)) end)
  end

  @doc "Refer `name` into `ns` so it resolves bare, as if defined there."
  def add_refer(ns, name, source_ns) do
    put_key({:refer, ns, name}, source_ns)
    :ok
  end

  @doc """
  Refer every public var of `source_ns` into `ns`.

  A snapshot taken when the `(ns …)` form runs, exactly as Clojure's
  `:refer :all` is: vars interned in the source afterwards do not
  appear. This has to run *after* the require has loaded the source,
  which is why it is a runtime op rather than a compile-time expansion.
  """
  def add_refer_all(ns, source_ns) do
    for name <- public_names(source_ns), do: add_refer(ns, name, source_ns)
    :ok
  end

  @doc """
  True when `name` is interned in `ns` itself — no refer, alias or
  core fallback consulted, but ancestors count (read-through).

  `fetch/2` deliberately searches all of those; a resolver asking "is
  this name local, or does it belong to somebody else?" needs the
  narrow question.
  """
  def local_var?(ns, name) do
    member?({ns, name})
  end

  @doc """
  The namespace `name` was referred into `ns` from, or nil.

  Var lookup consults refers automatically; the compile-time resolvers
  for protocol and multimethod targets have to ask, because they need
  the owning namespace rather than the value.
  """
  def refer_source(ns, name) do
    case lookup({:refer, ns, name}) do
      {:ok, source} -> source
      :error -> nil
    end
  end

  defp refer_candidate(ns, name) do
    case refer_source(ns, name) do
      nil -> []
      source -> [{source, name}]
    end
  end

  @doc """
  Record that `ns` exists, independently of whether anything is
  interned in it yet.

  A namespace is brought into being by `(ns …)`, not by its first
  `def`. Inferring existence from "has at least one var" made an empty
  or not-yet-populated namespace unrequirable, which is the ordinary
  shape of a file whose forms have not run yet, of a namespace holding
  only macros, and of any two namespaces that refer to each other.
  """
  def declare_ns(ns) when is_binary(ns) do
    put_key({:ns, ns}, true)
    :ok
  end

  @doc """
  True when `ns` has been declared by an `(ns …)` form, or has any var
  interned in it, anywhere in the env chain.

  The second half keeps namespaces created by other routes — `in_ns`,
  direct `intern`, the prelude's seeding — visible without each having
  to announce itself.
  """
  def ns_exists?(ns) do
    Enum.any?(chain(), fn env ->
      case :ets.lookup(@table, pfx(env, {:ns, ns})) do
        [{_, true}] ->
          true

        [] ->
          case :ets.match(@table, {pfx(env, {ns, :_}), :_}, 1) do
            {[_], _} -> true
            _ -> false
          end
      end
    end)
  end

  def loaded_ns?(ns) do
    Enum.any?(chain(), fn
      :global ->
        Agent.get(__MODULE__, &MapSet.member?(&1.loaded, ns))

      env ->
        case env_state(env) do
          %{loaded: loaded} -> MapSet.member?(loaded, ns)
          _ -> false
        end
    end)
  end

  def mark_loaded(ns) do
    case env_id() do
      :global ->
        Agent.update(__MODULE__, &%{&1 | loaded: MapSet.put(&1.loaded, ns)})

      env ->
        update_env_state(env, fn st -> %{st | loaded: MapSet.put(st.loaded, ns)} end)
    end
  end

  # --- var linking (BeamLisp.Link) ---
  # fn vars also live as named functions in a per-ns module; the
  # registry below lets call sites compile to direct remote calls.

  @doc "The def entries `{name => [{kind, arity, fname, def_ast}]}` backing ns's module."
  def ns_defs(ns) do
    case lookup({:ns_defs, ns}) do
      {:ok, defs} -> defs
      :error -> %{}
    end
  end

  def put_ns_defs(ns, defs), do: put_key({:ns_defs, ns}, defs)

  @doc """
  Every namespace that exists: defined something OR declared by `(ns …)`.

  Used to resolve a bare name when the current namespace is not the one
  that defines it — `current_ns/0` is process-global and outlives any
  single evaluation, so it is a hint rather than an answer.

  Declared namespaces are included because a namespace of plain `def`s has
  no `ns_defs` entry at all — `ns_defs` backs compiled `defn`s — so the
  narrower reading made a loaded, populated namespace invisible to anyone
  asking "what is loaded?" (the live-environment panel found exactly that:
  a contract-only namespace did not appear in its own listing).
  """
  def namespaces do
    chain()
    |> Enum.flat_map(fn env ->
      :ets.select(@table, [{{pfx(env, {:ns_defs, :"$1"}), :_}, [], [:"$1"]}]) ++
        :ets.select(@table, [{{pfx(env, {:ns, :"$1"}), :_}, [], [:"$1"]}])
    end)
    |> Enum.uniq()
  end

  @doc "Register link metadata `{module, %{arity => fname}, {min, vfname} | nil}` for a fn var."
  def put_link(ns, name, info), do: put_key({:link, ns, name}, info)

  @doc "Resolve link metadata with the same alias/refer/core rules as fetch/2."
  def link(ns, name) do
    cands = candidates(ns, name)

    Enum.find_value(chain(), :error, fn env ->
      Enum.find_value(cands, nil, fn {cns, cname} ->
        case :ets.lookup(@table, pfx(env, {:link, cns, cname})) do
          [{_, info}] -> {:ok, info}
          [] -> nil
        end
      end)
    end)
  end

  @doc """
  Record `meta` (a map) for `name` in `ns`. This is the general var
  metadata mechanism — `%{doc: "…"}`, `%{private: true}`,
  `%{dynamic: true}` and any other Clojure metadata keys all live in
  the one map. Writes **merge**: redefining a var with a new docstring
  keeps keys set earlier (so `:private` set on the first def survives a
  later doc-only redefinition) and the latest value wins per key. The
  merge base is chain-visible, so a fork refining a var's metadata merges
  onto the ancestor's copy and writes the result locally — the ancestor
  keeps its own.
  Returns `:ok`.
  """
  # is_map-ok: meta is the internal var-metadata map (compiler/REPL side
  # channel), never a user collection — structs are legitimate here.
  def put_meta(ns, name, meta) when is_map(meta) do
    merged =
      case lookup({:meta, ns, name}) do
        # is_map-ok: `existing` is the same internal metadata map from ETS.
        {:ok, existing} when is_map(existing) -> Map.merge(existing, meta)
        _ -> meta
      end

    put_key({:meta, ns, name}, merged)
    :ok
  end

  @doc "Read the metadata map recorded by `put_meta/3` for `name` in `ns` (no resolution)."
  def meta(ns, name), do: lookup({:meta, ns, name})

  @doc """
  Resolve `name` through the same alias/refer/core rules as `fetch/2`
  and return its docstring metadata.

  `name` is a var name string, or the quoted-symbol datum `{:symbol, name}`
  that `(doc 'foo)` hands over. Returns `%{ns: resolved_ns, name: resolved_name, doc: doc}`
  when a var with a docstring resolves, else `nil` (beam-lisp `doc` checks
  with `nil?` and reads the fields with `get`).
  """
  def doc_string(ns, name) do
    name = unwrap_doc_name(name)
    cands = candidates(ns, name)

    Enum.find_value(chain(), fn env ->
      Enum.find_value(cands, fn {cns, cname} ->
        case :ets.lookup(@table, pfx(env, {:meta, cns, cname})) do
          [{_, %{doc: doc}}] -> {cns, cname, doc}
          [] -> nil
        end
      end)
    end)
    |> case do
      {cns, cname, doc} -> %{ns: cns, name: cname, doc: doc}
      nil -> nil
    end
  end

  defp unwrap_doc_name({:symbol, name}), do: name
  defp unwrap_doc_name(name) when is_binary(name), do: name

  @doc """
  Directories the loader searches for `<ns>.bl` files, innermost first.

  The stack is a load-in-progress affair: at `:global` it stays in the
  Agent (byte-identical session behavior); in a fork it is process-local,
  so two processes loading concurrently in one env cannot corrupt each
  other's stack.
  """
  def load_paths do
    case env_id() do
      :global -> Agent.get(__MODULE__, & &1.load_paths)
      _ -> Process.get(:bl_load_paths, [])
    end
  end

  def push_load_path(dir) do
    case env_id() do
      :global -> Agent.update(__MODULE__, &%{&1 | load_paths: [dir | &1.load_paths]})
      _ -> Process.put(:bl_load_paths, [dir | load_paths()])
    end

    :ok
  end

  def pop_load_path do
    case env_id() do
      :global -> Agent.update(__MODULE__, &%{&1 | load_paths: tl(&1.load_paths)})
      _ -> Process.put(:bl_load_paths, tl(load_paths()))
    end

    :ok
  end

  @doc """
  Configured search paths — library roots the loader consults after cwd.

  Distinct from `load_paths/0`, and the distinction matters: load paths are a
  STACK scoped to a load in progress (pushed on entry, popped after), while
  search paths are ambient configuration for the whole session. Conflating
  them would make a configured root vanish the moment a nested require
  finished, which is exactly the bug shape `pop_load_path` exists to create
  for the stack.

  Reads walk the chain (own env's roots first, then ancestors'); writes
  land in the current env, so a test can add a fixture root without
  polluting its base image.
  """
  def search_paths do
    chain()
    |> Enum.flat_map(fn
      :global -> Agent.get(__MODULE__, &Map.get(&1, :search_paths, []))
      env ->
        case env_state(env) do
          %{search_paths: paths} -> paths
          _ -> []
        end
    end)
    |> Enum.uniq()
  end

  @doc "Append a search path (idempotent, order-preserving)."
  def add_search_path(dir) do
    dir = Path.expand(dir)

    case env_id() do
      :global ->
        Agent.update(__MODULE__, fn s ->
          paths = Map.get(s, :search_paths, [])
          if dir in paths, do: s, else: Map.put(s, :search_paths, paths ++ [dir])
        end)

      env ->
        update_env_state(env, fn st ->
          if dir in st.search_paths, do: st, else: %{st | search_paths: st.search_paths ++ [dir]}
        end)
    end
  end

  @doc "Drop the current env's configured search paths (test isolation)."
  def clear_search_paths do
    case env_id() do
      :global -> Agent.update(__MODULE__, &Map.put(&1, :search_paths, []))
      env -> update_env_state(env, &%{&1 | search_paths: []})
    end
  end

  def fetch!(ns, name) do
    case fetch(ns, name) do
      {:ok, value} -> value
      :error -> raise "undefined var: #{ns}/#{name}"
    end
  end

  def seeded? do
    Enum.any?(chain(), fn
      :global -> Agent.get(__MODULE__, & &1.seeded)
      _env -> false
    end)
  end

  def mark_seeded do
    case env_id() do
      :global -> Agent.update(__MODULE__, &%{&1 | seeded: true})
      _env -> :ok
    end
  end
end
