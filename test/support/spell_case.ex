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
  Modules and atoms allocated while running `fun`.

  The instrument PLAN-027 W1 is built around. `:code.all_loaded/0` is a linear
  scan and `atom_count` is a cheap VM counter; both are read on either side of
  the work, so what is measured is the work and not the measuring.
  """
  def allocations(fun) do
    modules_before = length(:code.all_loaded())
    atoms_before = :erlang.system_info(:atom_count)
    fun.()
    %{
      modules: length(:code.all_loaded()) - modules_before,
      atoms: :erlang.system_info(:atom_count) - atoms_before
    }
  end
end
