defmodule BeamLisp.Native do
  @moduledoc """
  `defnative` — a beam-lisp namespace that hosts a Rust NIF.

  ## Why this exists

  A NIF must be loaded into a BEAM module. Before this, the only way to
  get one was to hand-write an Elixir module whose function bodies all
  read `:erlang.nif_error(:nif_not_loaded)` — placeholders the VM
  overwrites at load time.

  That file contained no logic. It was a *declaration* that certain
  names are implemented natively, and nothing else. Yet it forced every
  native capability to enter the system through Elixir, which
  contradicts the doctrine the rest of the project follows: as much as
  possible in `.bl`, with Elixir keeping only substrate.

  A NIF is substrate. The *declaration* that one exists is not, and it
  belongs in the namespace that uses it:

      (ns datom.store-fjall)

      (defnative "datom_fjall"
        (fjall-open 1)
        (fjall-get 2)
        (fjall-put 3))

  After that, `(fjall-open "/tmp/db.fjall")` in that namespace calls Rust
  directly. No intermediate module, no stub file, nothing to keep in
  sync with the crate.

  ## How it works

  `declare/3` creates a host module named after the namespace, gives it
  one stub per declared function, and attaches an `@on_load` that loads
  `priv/native/lib<crate>`. The BEAM replaces every stub at load time.
  Each stub is then linked into the namespace as an ordinary beam-lisp
  var, so callers cannot tell it apart from a `.bl` function — which is
  the point.

  ## One crate, one namespace

  `rustler::init!("Elixir.BeamLisp.Native.Datom.StoreFjall")` names its
  host module at COMPILE time, so a crate can be loaded by exactly one
  namespace — the one whose name it was built for. A second namespace
  declaring the same crate gets `{:bad_lib, "Library module name ...
  does not match calling module ..."}` and `available?/1` answers false.

  That is a real constraint rather than an oversight, and it is the
  right one: the crate and the namespace are two halves of one
  interface, and the module name is how they agree on it. Sharing a
  crate between namespaces would mean the Rust side no longer knows who
  it is talking to.

  A crate meant for several namespaces should be split, or should export
  a single namespace that the others require.

  ## Name translation

  beam-lisp names are kebab-case; NIF names must match what
  `rustler::init!` exported, which is snake_case. `compare-and-swap`
  therefore hosts as `compare_and_swap`, and the var keeps its kebab
  spelling. The same convention `priv/boot/core.bl` already uses for its
  primitives.

  ## When the NIF is absent

  A checkout without a Rust toolchain still compiles: `@on_load` fails,
  the module is not loaded, and calls raise. `available?/1` answers the
  question without raising, so a `.bl` store can offer itself
  conditionally rather than exploding at require time. A native backend
  that cannot load must read as ABSENT, never as present-but-degraded.
  """

  @doc """
  Declare that `ns` is backed by the NIF crate `crate`.

  `signatures` is a list of `{name, arity}`. Returns the host module.
  """
  @spec declare(String.t(), String.t(), [{String.t(), non_neg_integer()}]) :: module()
  def declare(ns, crate, signatures) do
    # VM-wide critical section: the host module is created at RUNTIME, so
    # two envs loading the same native-backed namespace concurrently would
    # race Module.create ("currently being defined") — same fix as
    # BeamLisp.Record.define/3 (PLAN-046).
    :global.trans({host_module(ns), self()}, fn -> do_declare(ns, crate, signatures) end)
  end

  defp do_declare(ns, crate, signatures) do
    guard_against_duplicates!(ns, signatures)
    guard_against_shadowing!(ns, signatures)

    # Record it, so an AOT build can replay it from the namespace
    # module's `__bl_init__/0`. The host module is built at RUNTIME by
    # `Module.create`, so AOT never wrote it to disk — an AOT-compiled
    # deployment started with no native backend at all, `available?`
    # answered false, and the layer above quietly chose an in-memory
    # store. Silent loss of durability, discovered only when data failed
    # to survive a restart (BUG-021).
    :ets.insert(table(), {{:native, ns}, {crate, signatures}})

    mod = host_module(ns)

    unless Code.ensure_loaded?(mod) do
      create_host(mod, ns, crate, signatures)
    end

    for {name, arity} <- signatures do
      link_var(ns, mod, name, arity)
    end

    mod
  end

  @doc """
  Every native declaration made so far, as `{ns, {crate, signatures}}`.

  AOT reads this to replay declarations into the modules it emits.
  """
  @spec declarations() :: [{String.t(), {String.t(), [{String.t(), non_neg_integer()}]}}]
  def declarations do
    :ets.match_object(table(), {{:native, :_}, :_})
    |> Enum.map(fn {{:native, ns}, decl} -> {ns, decl} end)
  end

  @doc "The declaration for `ns`, or nil."
  @spec declaration(String.t()) :: {String.t(), [{String.t(), non_neg_integer()}]} | nil
  def declaration(ns) do
    case :ets.lookup(table(), {:native, ns}) do
      [{_, decl}] -> decl
      [] -> nil
    end
  end

  @table :beam_lisp_native_declarations

  # The declarations table is VM-wide state and must OUTLIVE whichever
  # process first declared a native. Created lazily by the first caller, it
  # died with that caller when the caller was a parallel-build worker (one
  # `Task` per source): every `defnative` namespace compiled after that
  # worker exited saw `declaration/1` → nil, its `__bl_init__` was emitted
  # WITHOUT the `Native.declare` replay, and the beam differed from a serial
  # build's — silently, a deployment with no native backend (BUG-021's exact
  # symptom, by a new route). Same fix as BeamLisp.LazySeq's table: the
  # pinned `Loader.Server` owns it, so its lifetime is the VM's.
  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        BeamLisp.Loader.Server.run(fn ->
          try do
            :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          rescue
            # Another process won the race; its table is the one we want.
            ArgumentError -> :ok
          end
        end)

        @table

      _ ->
        @table
    end
  end

  @doc """
  Whether the NIF for `ns` loaded.

  A capability question, not a health check: the caller decides what to
  do without one.
  """
  @spec available?(String.t()) :: boolean()
  def available?(ns) do
    mod = host_module(ns)

    # `function_exported?` is true either way — the stub is exported
    # too. Only CALLING it distinguishes loaded from not: the Rust
    # version returns true, the stub raises.
    Code.ensure_loaded?(mod) and mod.__nif_loaded__()
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # One name, one arity. A repeated name would register two links for
  # it, and the second would win — so the first declaration would
  # silently do nothing, and a call meant for it would reach a function
  # of a different arity. Erlang allows the same name at several
  # arities; this does not, because a beam-lisp var binds one function.
  defp guard_against_duplicates!(ns, signatures) do
    duplicates =
      signatures
      |> Enum.map(fn {name, _} -> name end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_, count} -> count > 1 end)
      |> Enum.map(fn {name, _} -> name end)

    if duplicates != [] do
      raise "defnative in #{ns}: #{Enum.join(duplicates, ", ")} declared more than once"
    end
  end

  # A native name that collides with a core function is REFUSED, because
  # the collision does not fail where it is written — it fails wherever
  # the namespace next uses the core function for its own purposes.
  #
  # Declaring `(get 2)` here rebinds `get` for the whole namespace, so a
  # later `(get op 0)` on a plain vector reaches the NIF with a vector
  # where it wants a database handle. The error names an arity mismatch
  # deep in a lazy map, hundreds of lines from the declaration, and says
  # nothing about shadowing.
  #
  # Prefixing (`fjall-get`) costs one word and removes the whole class.
  defp guard_against_shadowing!(ns, signatures) do
    clashes =
      signatures
      |> Enum.map(fn {name, _arity} -> name end)
      |> Enum.filter(fn name -> match?({:ok, _}, BeamLisp.Env.fetch("core", name)) end)

    if clashes != [] do
      raise """
      defnative in #{ns}: #{Enum.join(clashes, ", ")} would shadow core.

      A native name binds for the whole namespace, so the failure would
      surface wherever this file next calls the core function — with an
      error about argument types, far from the declaration.

      Prefix them: #{Enum.map_join(clashes, ", ", &"#{tag(ns)}-#{&1}")}
      """
    end
  end

  defp tag(ns), do: ns |> String.split(".") |> List.last() |> String.replace("store-", "")

  # `datom.store-fjall` → `BeamLisp.Native.Datom.StoreFjall`
  defp host_module(ns) do
    segments =
      ns
      |> String.split(".")
      |> Enum.map(&Macro.camelize(String.replace(&1, "-", "_")))

    Module.concat([BeamLisp.Native | segments])
  end

  defp create_host(mod, ns, crate, signatures) do
    # Rustler installs as `priv/native/<crate>.so` (no `lib` prefix), and
    # `:erlang.load_nif/2` wants the path WITHOUT the extension.
    #
    # A crate may live in a CONSUMER app (acid-shell's native/wayland_shm,
    # native/loom_paint), whose `:beam_lisp_native` compiler installs it into
    # THAT app's priv — not beam_lisp's. So resolve across every loaded app's
    # priv/native, consumer apps first, beam_lisp last; a NIF that exists
    # nowhere reports beam_lisp's path in the error (the historical default).
    lib_path = resolve_lib_path(crate)

    stubs =
      for {name, arity} <- signatures do
        fname = String.to_atom(String.replace(name, "-", "_"))
        args = Macro.generate_arguments(arity, mod)

        quote do
          def unquote(fname)(unquote_splicing(args)) do
            :erlang.nif_error(:nif_not_loaded)
          end
        end
      end

    body =
      quote do
        @compile no_type_check: true
        @on_load :__load_nif__

        def __load_nif__ do
          case :erlang.load_nif(unquote(String.to_charlist(lib_path)), 0) do
            :ok -> :ok
            # A missing or unbuildable NIF leaves the module unloaded
            # rather than crashing the whole compile. `available?/1`
            # then answers false and a caller can choose another store.
            # A load failure is REPORTED, always. It used to be silent
            # behind an env var, so an arity that disagreed with the
            # Rust function — or a stub list that had drifted from the
            # crate — left `available?` quietly answering false and the
            # backend simply absent. The caller then chose an in-memory
            # store and never learned why.
            #
            # `{:bad_lib, "Function not found"}` in particular names the
            # exact function whose signature does not match, which is
            # the whole diagnosis. Swallowing it wasted that.
            {:error, reason} ->
              IO.warn("""
              the NIF for #{unquote(ns)} did not load: #{inspect(reason)}

              crate:   #{unquote(crate)}
              library: #{unquote(lib_path)}.so

              A "Function not found" reason means a declared name or
              arity disagrees with the crate; run `mix compile` if the
              library is simply missing.
              """)

              :ok
          end
        end

        # Every function the NIF exports needs a stub here, including
        # this marker: `load_nif` REFUSES the whole library if the
        # module is missing one, with `{:bad_lib, "Function not found"}`.
        # That strictness is a feature — it means a stub list that has
        # drifted from the crate fails at load rather than at the first
        # call to whichever function was forgotten.
        #
        # Once loaded, the real `__nif_loaded__/0` comes from Rust and
        # returns true; unloaded, this stub raises, which is how
        # `available?/1` tells the two apart.
        def __nif_loaded__ do
          :erlang.nif_error(:nif_not_loaded)
        end

        unquote_splicing(stubs)
      end

    Module.create(mod, body, Macro.Env.location(__ENV__))
    mod
  end

  # Search order: every loaded OTP app's priv/native (beam_lisp last), so a
  # consumer's crate wins over an identically named one in beam_lisp's priv.
  # Returns the extension-less path load_nif wants; falls back to beam_lisp's
  # priv when nothing exists, so the load error names a sensible location.
  defp resolve_lib_path(crate) do
    apps =
      Application.loaded_applications()
      |> Enum.map(fn {app, _, _} -> app end)
      |> Enum.reject(&(&1 == :beam_lisp))
      |> Kernel.++([:beam_lisp])

    found =
      Enum.find_value(apps, fn app ->
        case :code.priv_dir(app) do
          {:error, _} -> nil
          dir ->
            p = Path.join(to_string(dir), "native/#{crate}")
            if File.exists?(p <> ".so"), do: p, else: nil
        end
      end)

    found || Path.join(:code.priv_dir(:beam_lisp), "native/#{crate}")
  end

  defp link_var(ns, mod, name, arity) do
    fname = String.to_atom(String.replace(name, "-", "_"))

    # Two registrations, because a name is reachable two ways.
    #
    # `put_link` carries the `{module, %{arity => fname}, variadic}`
    # shape the COMPILER reads to emit a direct call — the same
    # mechanism `priv/boot/core.bl` primitives use, and what makes
    # `(compare-and-swap h k old new)` compile to a plain remote call
    # with no dispatch overhead.
    #
    # `put` binds the var itself, so the name also works as a VALUE:
    # passed to `map`, stored, partially applied. A native function that
    # could only be called and never passed would be a second-class
    # citizen in a language where functions are values.
    BeamLisp.Env.put_link(ns, name, {mod, %{arity => fname}, nil})
    BeamLisp.Env.intern(ns, name, Function.capture(mod, fname, arity))
  end
end
