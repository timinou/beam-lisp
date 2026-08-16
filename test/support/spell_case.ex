defmodule BeamLisp.SpellCase do
  @moduledoc """
  The shared preamble for every spell suite: the runtime up, the namespaces
  loaded, once per VM.

  `BeamLisp.Spell.init!/1` is idempotent but not free — it walks the loader for
  every namespace in the manifest. Doing it in each `setup` made a suite pay it
  per test; doing it once, guarded by a named process, makes the whole spell
  test tree pay it once.

  `async: false` throughout, and that is not laziness: `BeamLisp.Env` is a
  process-global ETS table and `spell.define`'s vars are interned into it, so
  two suites running concurrently would be defining over each other. The
  isolation this codebase actually has is "one machine value threaded through
  pure functions" — which is plenty, as long as the tests do not share the
  MUTABLE var namespace.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import BeamLisp.SpellCase
    end
  end

  setup_all do
    ensure_loaded!()
    :ok
  end

  @doc """
  Load the spell namespaces once per VM.

  Guarded by `:persistent_term` rather than by a process: the flag has to
  survive whatever supervision the app does around it, and it is written once
  and read on every suite.
  """
  def ensure_loaded! do
    case :persistent_term.get({__MODULE__, :loaded}, false) do
      true ->
        :ok

      false ->
        BeamLisp.Spell.init!(["spell.app", "spell.define", "spell.live"])
        :persistent_term.put({__MODULE__, :loaded}, true)
        :ok
    end
  end

  @doc """
  The seeded machine, as a beam-lisp VALUE.

  Fetched through `BeamLisp.Env` rather than built by `eval_string`, for the
  reason PLAN-027 W1 exists: `eval_string` compiles a fresh module per call, so
  a suite that builds its fixture that way leaks a module per test and measures
  nothing about the code under test.
  """
  def seeded_machine do
    empty = fetch!("spell.machine", "empty-machine")
    seeded = fetch!("spell.live", "seeded")
    contract = fetch!("spell.seed", "contract-term")
    view = fetch!("spell.seed", "view-term")
    seeded.(empty.(), contract, view)
  end

  @doc "A beam-lisp var's value, or a failure naming what was missing."
  def fetch!(ns, name) do
    case BeamLisp.Env.fetch(ns, name) do
      {:ok, value} -> value
      :error -> raise "no beam-lisp var #{ns}/#{name} — is the namespace loaded?"
    end
  end

  @doc """
  A beam-lisp value as plain Elixir data (vectors → lists, keywords → strings).

  Test-local on purpose while W1 is in flight: production gets one converter in
  `BeamLisp.Spell.Data`, and these tests must be able to describe the CURRENT
  behaviour before that exists, or they cannot witness the change.
  """
  def plain(%BeamLisp.Vector{} = v), do: Enum.map(BeamLisp.Vector.to_list(v), &plain/1)
  def plain(list) when is_list(list), do: Enum.map(list, &plain/1)

  def plain(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom),
    do: Atom.to_string(atom)

  def plain(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(plain(k)), plain(v)} end)

  def plain(other), do: other

  @doc """
  Modules and atoms allocated by `fun` in STEADY STATE.

  The instrument PLAN-027 W1 is built around. `:code.all_loaded/0` is a linear
  scan and `atom_count` is a cheap VM counter; both are read on either side of
  the work, so what is measured is the work and not the measuring.

  ## Why it counts EVAL modules and not all modules

  `:code.all_loaded/0` is VM-global, and `mix test` runs suites concurrently:
  another suite lazily loading an Elixir stdlib module lands in the same count
  and reads as a leak here. Measured: a pure `Map.new/2` loop "allocated" 3–4
  modules when the suite ran alongside others, and 0 when it ran alone.

  What is actually being asserted is narrower and fully attributable:
  `BeamLisp.Compiler.eval_string/1` compiles each call into a module named
  `Elixir.BeamLisp.Eval.M<n>`. Nothing else in the VM creates those. Counting
  exactly them answers the real question — "did this path compile beam-lisp
  source?" — and is immune to whatever the rest of the suite is doing.

  Atoms stay a global count because there is no attributable equivalent, and a
  small tolerance covers concurrent noise. `eval_string` interns ~2 atoms PER
  CALL, so a real leak over 50 events is ~100 — two orders of magnitude above
  the handful another suite contributes.

  ## Why it runs the work before measuring it

  A first call into a beam-lisp namespace links its module and interns its
  names, and a first call down a particular BRANCH links whatever that branch
  reaches. Measured on `Spell.Server.info/3`: the first pass over 200 tokens
  interned 9 atoms; the second interned none. That is a one-time cost of
  reaching the code, not a per-event leak, and reporting it as one would be
  crying wolf at exactly the assertion that must stay trustworthy.

  ## What this proves, and what it does not

  It catches a PROPORTIONAL leak -- one allocation per unit of work -- because
  warming with `n` iterations and then measuring `n` more still sees `n` leaked
  allocations. That is the leak that existed (`eval_string` compiled a module
  per event, per token) and the one the assertions below are about.

  It is blind to three shapes, and saying so is the point of this paragraph:

    * once per PROCESS -- the warm-up and the measurement run in the same test
      process, so a per-process cost is already paid when the reading starts;
    * once per DISTINCT PAYLOAD -- if the warm-up reuses one input, a leak keyed
      on the input's shape is already paid. The suites vary their payloads
      (`m<i>`, `tok<i>`) specifically to keep this partly covered;
    * on a BRANCH the warm-up does not take -- an allocation behind a condition
      only some inputs satisfy.

  A per-visitor leak would surface as a per-process one, which is why the mount
  case measures repeated mounts rather than trusting the event case to cover it.
  Nothing here proves the ABSENCE of every leak; it proves the absence of the
  one that was there.
  """
  def allocations(fun, opts \\ []) do
    for _ <- 1..Keyword.get(opts, :warmup, 2), do: fun.()

    eval_before = eval_modules()
    atoms_before = :erlang.system_info(:atom_count)
    fun.()

    %{
      modules: eval_modules() - eval_before,
      atoms: :erlang.system_info(:atom_count) - atoms_before
    }
  end

  @doc """
  How many `BeamLisp.Eval.M*` modules exist right now.

  One per `Compiler.eval_string/1` call, ever. The single number that answers
  "is this path compiling beam-lisp source?" without depending on what the rest
  of the VM is doing.
  """
  def eval_modules do
    Enum.count(:code.all_loaded(), fn {module, _} ->
      case Atom.to_string(module) do
        "Elixir.BeamLisp.Eval.M" <> _ -> true
        _ -> false
      end
    end)
  end
end
