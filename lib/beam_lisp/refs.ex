defmodule BeamLisp.Atom do
  @moduledoc """
  A reference whose value can be read and atomically swapped:
  beam-lisp's `(atom v)`, backed by an Elixir `Agent`. Mirrors
  Clojure's atom: `deref` reads, `swap!` applies, `reset!` sets,
  `compare-and-set!` CASes. The Agent serializes access, so there is
  no need for Clojure's CAS-retry loop.
  """
  defstruct [:pid]
end

defmodule BeamLisp.Promise do
  @moduledoc """
  A single-assignment reference: `deref` blocks until `deliver` sets
  a value, then returns it forever. Backed by a small process, so
  `deref` is an asynchronous wait, never a poll.
  """
  defstruct [:pid]
end

defmodule BeamLisp.Future do
  @moduledoc """
  A reference to a computation already running on the BEAM
  (`(future body…)`). `deref` blocks until the task returns.
  """
  defstruct [:task]
end

defmodule BeamLisp.Refs do
  @moduledoc """
  Clojure's reference types, on the BEAM.

  * `atom` — an `Agent` holding a value
  * `future` — a `Task` running a computation
  * `promise` — a single-assignment box

  `deref` blocks for futures and promises, and reads atoms
  immediately. All functions are plain module fns so they link to
  direct calls from compiled beam-lisp code.
  """

  # --- atoms ---

  def atom(v) do
    {:ok, pid} = Agent.start_link(fn -> v end)
    %BeamLisp.Atom{pid: pid}
  end

  def swap!(ref, f), do: swap!(ref, f, [])

  # Agent.get_and_update runs the fn inside the Agent process, which
  # serializes swaps — `{new, new}` stores the new value and returns
  # it to the caller.
  def swap!(%BeamLisp.Atom{} = atom, f, args_list) do
    Agent.get_and_update(atom.pid, fn current ->
      new = BeamLisp.RT.invoke(f, [current | args_list])
      {new, new}
    end)
  end

  def swap!(other, _f, _args_list) do
    raise ArgumentError, message: "swap!: not a reference: #{inspect(other)}"
  end

  def reset!(%BeamLisp.Atom{} = atom, v), do: Agent.get_and_update(atom.pid, fn _ -> {v, v} end)

  def reset!(other, _v), do: raise(ArgumentError, "reset!: not an atom: #{inspect(other)}")

  # Clojure's `=` is beam-lisp's `==`; match that.
  def compare_and_set!(%BeamLisp.Atom{} = atom, old, new) do
    Agent.get_and_update(atom.pid, fn current ->
      if current == old, do: {true, new}, else: {false, current}
    end)
  end

  def compare_and_set!(other, _old, _new) do
    raise ArgumentError, message: "compare-and-set!: not an atom: #{inspect(other)}"
  end

  # --- futures ---

  def future_exec(thunk_fn), do: %BeamLisp.Future{task: Task.async(thunk_fn)}
  def future?(%BeamLisp.Future{}), do: true
  def future?(_), do: false

  def future_cancel(%BeamLisp.Future{} = f) do
    # :brutal_kill terminates a running task immediately; it returns
    # nil (no reply), so gate the return on whether the task was
    # still alive — Clojure's future-cancel is true only when it
    # actually cancelled a running computation.
    running = Process.alive?(f.task.pid)
    Task.shutdown(f.task, :brutal_kill)
    running
  end

  def future_cancel(other) do
    raise ArgumentError, message: "future-cancel: not a future: #{inspect(other)}"
  end

  # --- promises ---

  def promise, do: %BeamLisp.Promise{pid: spawn(fn -> promise_loop(:unset, []) end)}

  # deliver returns the promise on first delivery, nil on any later
  # one — Clojure allows only a single delivery, and the nil return
  # lets callers detect the no-op.
  def deliver(%BeamLisp.Promise{} = p, v) do
    pid = p.pid
    send(pid, {:bl_set, self(), v})

    receive do
      {^pid, :bl_set_ack, true} -> p
      {^pid, :bl_set_ack, false} -> nil
    end
  end

  def deliver(other, _v), do: raise(ArgumentError, "deliver: not a promise: #{inspect(other)}")

  # The promise process holds `:unset` (plus a waiter list) or
  # `{:set, v}`. deref just registers as a waiter; the process
  # replies once the value arrives — no polling anywhere. Replies
  # carry the promise's pid so a timed-out deref can never confuse
  # one promise's value with another's.
  defp promise_loop(:unset, waiters) do
    receive do
      {:bl_deref, from} ->
        promise_loop(:unset, [from | waiters])

      {:bl_set, from, v} ->
        Enum.each(Enum.reverse(waiters), &send(&1, {self(), :bl_value, v}))
        send(from, {self(), :bl_set_ack, true})
        promise_loop({:set, v})
    end
  end

  defp promise_loop({:set, v}) do
    receive do
      {:bl_deref, from} ->
        send(from, {self(), :bl_value, v})
        promise_loop({:set, v})

      {:bl_set, from, _v} ->
        send(from, {self(), :bl_set_ack, false})
        promise_loop({:set, v})
    end
  end

  # --- deref ---

  def deref(%BeamLisp.Atom{} = atom), do: Agent.get(atom.pid, & &1)

  # Clojure's deref on a future blocks indefinitely.
  def deref(%BeamLisp.Future{} = f), do: Task.await(f.task, :infinity)

  def deref(%BeamLisp.Promise{} = p), do: deref(p, :infinity, nil)

  def deref(other), do: raise(ArgumentError, "deref: not a derefable reference: #{inspect(other)}")

  def deref(%BeamLisp.Atom{} = atom, _timeout_ms, _timeout_val), do: Agent.get(atom.pid, & &1)

  def deref(%BeamLisp.Future{} = f, timeout_ms, timeout_val) do
    try do
      Task.await(f.task, timeout_ms)
    catch
      :exit, {:timeout, _} -> timeout_val
    end
  end

  def deref(%BeamLisp.Promise{} = p, timeout_ms, timeout_val) do
    pid = p.pid
    send(pid, {:bl_deref, self()})

    receive do
      {^pid, :bl_value, v} -> v
    after
      timeout_ms -> timeout_val
    end
  end

  def deref(other, _timeout_ms, _timeout_val) do
    raise ArgumentError, message: "deref: not a derefable reference: #{inspect(other)}"
  end
end
