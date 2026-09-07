defmodule BeamLisp.Atom do
  @moduledoc """
  A reference whose value can be read and atomically swapped:
  beam-lisp's `(atom v)`, backed by a native memo cell. Mirrors Clojure's
  atom: `deref` reads, `swap!` applies, `reset!` sets, `compare-and-set!`
  CASes.

  The value lives in one GC-owned cell; `swap!` is a compare-exchange retry
  loop, the loop Clojure's atom runs and the old Agent version avoided by
  serializing in a process. The cell makes that loop cheaper than an Agent
  round-trip, and it removes the process: an atom is now a value held behind
  a reference, not a running process, so it survives as long as any holder
  keeps it (as in Clojure) rather than dying with a linked Agent.

  `watches` is a SECOND cell holding `%{key => fn}`. Watches therefore share
  the same ownership discipline as the value and need no process-dictionary
  side table.
  """
  defstruct [:cell, :watches]
end


defmodule BeamLisp.Volatile do
  @moduledoc """
  beam-lisp's `(volatile! v)` — Clojure's unsynchronized mutable box,
  on the BEAM.

  The value lives in the **process dictionary** of the process that
  created it, keyed by a unique reference. `deref` reads it, `vreset!`
  overwrites it, `vswap!` reads-and-writes, and all three are plain
  dictionary operations — no Agent, no message passing, no serialization.
  That is deliberately cheaper than an atom, honouring the deal Clojure's
  volatiles make with stateful transducers: the reduction is
  single-threaded by contract, so the box needs no coordination.

  **What this guarantees:** reads and writes are atomic *within the
  creating process*, and that is all. A transducer reduction runs in one
  process, so every volatile it touches lives there.

  **What it does NOT guarantee:** cross-process visibility, cross-process
  atomicity, or survival of the creating process. A volatile is not an
  atom: it will not and cannot coordinate two processes. If a value must
  cross a process boundary, use `(atom v)`. The struct holds only the
  dictionary key, never the value, so it is safe to send anywhere; the
  value simply is not visible outside its home process.
  """
  defstruct [:key]
end

defmodule BeamLisp.Reduced do
  @moduledoc """
  Clojure's `Reduced` sentinel: wraps a value so a `reduce` terminates
  early with it. `reduce` returns the *unwrapped* value when the step
  function yields a Reduced (the sentinel is peeled at the halting
  point); `reduced?` tests for the wrapper, and `deref`/`unreduced` peel
  it by hand. Structurally a plain one-field struct, so `=` distinguishes
  it from the value it carries.
  """
  defstruct [:value]
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
    %BeamLisp.Atom{cell: BeamLisp.LazyMemo.create_ref(v), watches: BeamLisp.LazyMemo.create_ref(%{})}
  end

  def swap!(ref, f), do: swap!(ref, f, [])

  # Compare-exchange retry loop: read the current value, apply f, publish with
  # exchange. A concurrent writer makes exchange answer :retry, and we re-read
  # and re-apply — Clojure's atom contract. Watches fire AFTER the value
  # commits, in the caller's process, exactly as before.
  def swap!(%BeamLisp.Atom{cell: cell} = atom, f, args_list) do
    old = BeamLisp.LazyMemo.read(cell)
    new = BeamLisp.RT.invoke(f, [old | args_list])

    case BeamLisp.LazyMemo.exchange_ref(cell, old, new) do
      :ok ->
        notify_watches(atom, old, new)
        new

      :retry ->
        swap!(atom, f, args_list)

      :cycle ->
        raise ArgumentError, "swap!: the new value would form a reference cycle"
    end
  end

  def swap!(other, _f, _args_list) do
    raise ArgumentError, message: "swap!: not a reference: #{inspect(other)}"
  end

  def reset!(%BeamLisp.Atom{cell: cell} = atom, v) do
    old = BeamLisp.LazyMemo.read(cell)

    case BeamLisp.LazyMemo.exchange_ref(cell, old, v) do
      :ok -> notify_watches(atom, old, v); v
      :retry -> reset!(atom, v)
      :cycle -> raise ArgumentError, "reset!: the value would form a reference cycle"
    end
  end

  def reset!(other, _v), do: raise(ArgumentError, "reset!: not an atom: #{inspect(other)}")

  # --- watches (PLAN-148 W6a) ---
  #
  # Clojure's `add-watch` / `remove-watch`, which beam-lisp did not have: atoms
  # supported deref/swap!/reset!/compare-and-set! but nothing could OBSERVE a
  # change. That gap is what stands between an atom and an automatic connector
  # (`st/connect!`), where an ordinary `swap!` must drive a UI.
  #
  # The watch table lives in the AGENT's process dictionary, not in the Agent's
  # state. The state stays exactly the bare value, so `deref` and every existing
  # operation are untouched and no stored atom changes shape.
  #
  # Watches fire in the CALLER's process, after the swap has committed — as in
  # Clojure. Running them inside the Agent would block it, and a watch that
  # touched its own atom would deadlock.

  @doc "Register `f` under `key`; it is called `(f key ref old new)` on change."
  def add_watch!(%BeamLisp.Atom{watches: w} = atom, key, f) do
    update_watches(w, &Map.put(&1, key, f))
    atom
  end

  def add_watch!(other, _key, _f) do
    raise ArgumentError, message: "add-watch!: not an atom: #{inspect(other)}"
  end

  @doc "Remove the watch registered under `key`."
  def remove_watch!(%BeamLisp.Atom{watches: w} = atom, key) do
    update_watches(w, &Map.delete(&1, key))
    atom
  end

  def remove_watch!(other, _key) do
    raise ArgumentError, message: "remove-watch!: not an atom: #{inspect(other)}"
  end

  # CAS-loop on the watches cell, so concurrent add/remove do not lose each other.
  defp update_watches(cell, f) do
    old = BeamLisp.LazyMemo.read(cell)

    case BeamLisp.LazyMemo.exchange_ref(cell, old, f.(old)) do
      :ok -> :ok
      :retry -> update_watches(cell, f)
      :cycle -> raise ArgumentError, "watch table would form a reference cycle"
    end
  end

  defp notify_watches(%BeamLisp.Atom{watches: w} = atom, old, new) do
    # A no-op change still notifies, matching Clojure: the watch decides what
    # counts as a change, not the atom.
    case BeamLisp.LazyMemo.read(w) do
      watches when map_size(watches) == 0 ->
        :ok

      watches ->
        Enum.each(watches, fn {key, f} ->
          BeamLisp.RT.invoke(f, [key, atom, old, new])
        end)
    end
  end

  # Clojure's `=` is beam-lisp's `==`; match that.
  def compare_and_set!(%BeamLisp.Atom{cell: cell} = atom, old, new) do
    # Clojure `compare-and-set!` compares with `=` (value equality), so `1` and
    # `1.0` count as equal; the native exchange compares EXACTLY. Do the
    # value-equality check here against the current term, then exchange against
    # that exact term so the swap is still atomic: a racing writer changes the
    # term, the exact exchange answers :retry, and we re-check.
    current = BeamLisp.LazyMemo.read(cell)

    if current == old do
      case BeamLisp.LazyMemo.exchange_ref(cell, current, new) do
        :ok -> notify_watches(atom, current, new); true
        :retry -> compare_and_set!(atom, old, new)
        :cycle -> raise ArgumentError, "compare-and-set!: the value would form a reference cycle"
      end
    else
      false
    end
  end

  def compare_and_set!(other, _old, _new) do
    raise ArgumentError, message: "compare-and-set!: not an atom: #{inspect(other)}"
  end


  # --- volatiles ---
  # A volatile is an *unsynchronized* box (see the BeamLisp.Volatile
  # moduledoc): a process-dictionary cell, not an Agent. That is the
  # whole point — the transducer layer creates and swaps a volatile per
  # step, so spawning a process for each would forfeit the performance
  # deal. The cost is the documented honesty: visible only within the
  # creating process. Single-threaded reductions get the speed, and
  # anything that needs to coordinate processes is told to use `atom`.

  def volatile(v) do
    key = make_ref()
    Process.put({BeamLisp.Volatile, key}, v)
    %BeamLisp.Volatile{key: key}
  end

  def vreset!(%BeamLisp.Volatile{} = vol, v) do
    Process.put({BeamLisp.Volatile, vol.key}, v)
    v
  end

  def vreset!(other, _v), do: raise(ArgumentError, "vreset!: not a volatile: #{inspect(other)}")

  def vswap!(vol, f), do: vswap!(vol, f, [])

  # Like swap!, the step fn runs in the caller's process (no Agent), so
  # read-modify-write is atomic only against other ops in the same
  # process — which is exactly the volatile contract.
  def vswap!(%BeamLisp.Volatile{} = vol, f, args_list) do
    new = BeamLisp.RT.invoke(f, [deref(vol) | args_list])
    Process.put({BeamLisp.Volatile, vol.key}, new)
    new
  end

  def vswap!(other, _f, _args_list) do
    raise ArgumentError, "vswap!: not a volatile: #{inspect(other)}"
  end

  def volatile?(%BeamLisp.Volatile{}), do: true
  def volatile?(_), do: false

  # --- futures ---


  # A fork's :max_heap_words bound is enforced per spawned process
  # (PLAN-047 W5): the token carries it, and the process sets its own
  # max_heap_size flag — overflow kills THIS process, never the VM.
  defp apply_heap_bound do
    case BeamLisp.Env.max_heap() do
      nil -> :ok
      # Map form, kill: false — the integer form exits :killed, which is
      # UNTRAPPABLE and would take the awaiting caller down through the
      # task link. Non-kill overflow raises in the bounded process, so
      # deref surfaces it like any other error.
      words ->
        :erlang.process_flag(:max_heap_size, %{size: words, kill: false, error_logger: false})
    end
  end

  def future_exec(thunk_fn) do
    # Carry the caller's env binding into the task: pdict does not
    # propagate across spawn, and a future that landed in :global would
    # silently escape its test's isolated env (PLAN-046 L2).
    token = BeamLisp.Env.capture()
    %BeamLisp.Future{task: Task.async(fn -> BeamLisp.Env.bind(token); apply_heap_bound(); thunk_fn.() end)}
  end

  # A beam-lisp process that INHERITS the spawning env, the same
  # binding-conveyance `future_exec/1` and `promise/0` use. Raw
  # `:erlang.spawn` starts a child with an EMPTY process dict, so the
  # child resolves its vars and caps at `:global` — a child spawned
  # inside an isolated fork (a test, a sandbox, an example under ward)
  # cannot see the very namespace that spawned it, and blocks or crashes.
  # Capturing the token here and binding it first makes `spawn` env-
  # transparent: the child runs in the SAME world as its parent, exactly
  # as Clojure conveys dynamic bindings across `future`. `spawn_kind` is
  # `:plain | :link | :monitor`, mirroring the three `:erlang.spawn*`
  # shapes; `:monitor` returns a `{pid, ref}` tuple as Erlang does.
  def spawn_exec(thunk_fn), do: spawn_exec(thunk_fn, :plain)

  def spawn_exec(thunk_fn, kind) do
    token = BeamLisp.Env.capture()
    wrapped = fn -> BeamLisp.Env.bind(token); apply_heap_bound(); thunk_fn.() end

    case kind do
      :plain -> :erlang.spawn(wrapped)
      :link -> :erlang.spawn_link(wrapped)
      :monitor -> :erlang.spawn_monitor(wrapped)
    end
  end
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

  def promise do
    # Same propagation as future_exec/1: the promise's loop process
    # inherits the caller's env binding.
    token = BeamLisp.Env.capture()
    %BeamLisp.Promise{pid: spawn(fn -> BeamLisp.Env.bind(token); apply_heap_bound(); promise_loop(:unset, []) end)}
  end

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

  def deref(%BeamLisp.Atom{cell: cell}), do: BeamLisp.LazyMemo.read(cell)

  # Clojure's deref on a future blocks indefinitely.
  def deref(%BeamLisp.Future{} = f), do: Task.await(f.task, :infinity)

  def deref(%BeamLisp.Promise{} = p), do: deref(p, :infinity, nil)

  def deref(%BeamLisp.Volatile{} = vol), do: Process.get({BeamLisp.Volatile, vol.key})
  def deref(%BeamLisp.Reduced{} = r), do: r.value
  # A delay derefs to its value, forcing it once. `@d` therefore works on a
  # delay exactly as on an atom or promise.
  def deref(%BeamLisp.Delay{} = d), do: BeamLisp.Deferred.force(d)
  # A derived derefs to its current value, recomputing only if a dependency
  # changed. `@d` on a derived reads it exactly like an atom.
  def deref(%BeamLisp.Derived{} = d), do: BeamLisp.Reactive.deref(d)

  def deref(other), do: raise(ArgumentError, "deref: not a derefable reference: #{inspect(other)}")

  def deref(%BeamLisp.Atom{cell: cell}, _timeout_ms, _timeout_val), do: BeamLisp.LazyMemo.read(cell)

  def deref(%BeamLisp.Future{} = f, timeout_ms, timeout_val) do
    try do
      Task.await(f.task, timeout_ms)
    catch
      :exit, {:timeout, _} -> timeout_val
    end
  end

  def deref(%BeamLisp.Volatile{} = vol, _timeout_ms, _timeout_val), do: Process.get({BeamLisp.Volatile, vol.key})
  def deref(%BeamLisp.Reduced{} = r, _timeout_ms, _timeout_val), do: r.value

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
