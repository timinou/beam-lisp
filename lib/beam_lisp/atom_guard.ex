defmodule BeamLisp.AtomGuard do
  @moduledoc """
  The one place beam-lisp decides it is unsafe to intern another atom.

  Erlang atoms are never garbage collected and a full atom table does
  not raise — it **aborts the whole VM**, uncatchably, with a crash
  dump. beam-lisp's position is that compiler input is trusted code
  (see `docs/trust-boundary.md`), but "trusted" is a statement about
  intent, not about size: generated source, a long REPL session with
  gensym-heavy macros, or a merely enormous file can all walk the table
  upward without anyone meaning harm.

  So every layer that turns source text into atoms samples the table
  through here and refuses *before* the VM would die, converting an
  unrecoverable abort into an ordinary catchable error naming the token
  that tipped it over.

  ## Why sampling rather than counting

  `:erlang.system_info(:atom_count)` is cheap but not free, and it is
  asked once per `interval` interned names rather than once per name —
  measured at read-path noise (396.4ms → 393.2ms over a 1.5MB source,
  roughly 40k tokens). The counter lives in the process dictionary, so
  there is no shared cell to contend on and no cross-process race; each
  reader or compiler process carries its own.

  The consequence to be honest about: the guard samples the **absolute**
  VM atom count, not this program's contribution to it. It cannot stop a
  single form that interns a million names between two samples. It is a
  high-water alarm, not a quota.

  ## Configuration

    * `:beam_lisp, :atom_high_water_fraction` — fraction of
      `:erlang.system_info(:atom_limit)` at which to refuse. Default
      `0.9`.
    * `:beam_lisp, :atom_check_interval` — how many interned names
      between samples. Default `256`.
  """

  defmodule LimitError do
    @moduledoc """
    Raised when interning another atom would take the VM too close to a
    table it cannot survive filling.
    """
    defexception [:message]
  end

  @default_high_water 0.9
  @default_check_interval 256
  @count_key {__MODULE__, :count}

  @doc """
  Account for one about-to-be-interned name, sampling the atom table
  every `:atom_check_interval` calls.

  `token` is the source text that prompted the intern; it is only used
  to name the culprit in the error, so pass whatever a reader of the
  message would find most useful.
  """
  def account!(token) do
    count = Process.get(@count_key, 0) + 1
    Process.put(@count_key, count)

    if rem(count, check_interval()) == 0, do: check!(token)

    :ok
  end

  @doc """
  Intern `name` as an atom, refusing if the table is at its high-water
  mark. The safe replacement for a bare `String.to_atom/1` on any name
  that came from source text.

  Tries `String.to_existing_atom/1` first: a name beam-lisp has already
  seen — every re-read of the same keyword in a REPL session, every
  recompile of the same namespace — costs nothing and cannot grow the
  table, so the guard only has to think about genuinely new names.
  """
  def to_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError ->
      account!(name)
      String.to_atom(name)
  end

  @doc """
  Raise unless the atom table is below its high-water mark. Call
  directly when a single operation is about to intern many names at
  once, where per-name sampling would look at the table too late.
  """
  def check!(token) do
    count = :erlang.system_info(:atom_count)
    limit = :erlang.system_info(:atom_limit)
    fraction = high_water_fraction()

    if count >= round(limit * fraction) do
      raise LimitError,
        message:
          "refusing to intern #{inspect(token)}: the VM atom table holds #{count} of " <>
            "#{limit} atoms, at or past the configured high-water fraction #{fraction}. " <>
            "Atoms are never collected, the table only grows, and filling it aborts the " <>
            "whole VM rather than raising — so beam-lisp stops here instead. Adjust " <>
            ":beam_lisp, :atom_high_water_fraction to change the ceiling."
    end

    :ok
  end

  @doc "Reset the per-process intern counter. Called at the start of a read."
  def reset, do: Process.put(@count_key, 0)

  @doc "The configured high-water fraction, clamped to 0.0..1.0."
  def high_water_fraction do
    case Application.get_env(:beam_lisp, :atom_high_water_fraction, @default_high_water) do
      f when is_number(f) -> min(max(f, 0.0), 1.0)
      _ -> @default_high_water
    end
  end

  @doc "How many interned names pass between table samples (at least 1)."
  def check_interval do
    case Application.get_env(:beam_lisp, :atom_check_interval, @default_check_interval) do
      i when is_number(i) -> max(trunc(i), 1)
      _ -> @default_check_interval
    end
  end
end
