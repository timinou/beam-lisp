defmodule BeamLisp.NifTrace do
  @moduledoc """
  A flight recorder for native calls, built on the VM's own tracer.

  ## Why this exists

  A segfault inside a NIF returns no exception, no stack and no message. When it
  kills the VM, the only question worth answering is which call was in flight,
  and the only place that answer survives is outside the process. A core dump
  answers it too, but costs gdb, registers and a reading of the vendored Rust —
  and earlier rounds of this investigation paid that repeatedly to learn things
  this recorder reports in one run.

  ## Why it is built this way

  The first version wrote a line from inside `BeamLisp.LazyMemo`, immediately
  before each NIF invocation. It worked: it named `nif_compare_exchange_fast/6`
  as the call in flight when the VM died. It also paid for the answer in the hot
  path, and that cost is measurable — `test/bl/build_test.bl` failed two runs in
  three with it live and zero in three with it inert. Instrumentation that
  changes what it observes is not instrumentation.

  `:erlang.trace/3` gets the same answer without touching the observed code. The
  trace fires on the **Erlang-level call** — the stub that `load_nif` replaces —
  which is exactly the boundary worth marking, because it is the last moment the
  VM is still running Erlang. Nothing runs in the observed path; when the
  recorder is off, no code at all runs for it.

  ## Why the write is unsynced

  Unsynced is the point, not an optimisation. A completed `write(2)` lives in the
  kernel's page cache, so it survives the process being killed by a signal.
  `fsync` protects against losing the machine, not against losing the VM. The
  last line in the file is therefore the call that was in flight, whatever
  happened next.

  ## What it can and cannot see

  It reports the Erlang-level call. A function that `load_nif` has replaced with
  a NIF is NOT traceable — the VM does not run the Erlang body, so no trace
  message is generated for it. The recorder therefore names the last Erlang
  function that ran, which for this crate is the funnel: `BeamLisp.LazyMemo.create/1`,
  `exchange/4`, `cursor/1`. That is enough to say which work was in flight and
  which cell was being touched, and it costs nothing to collect.

  It is NOT enough to name the exact native entry point — the earlier recorder,
  which wrote from inside the funnel, could say `nif_compare_exchange_fast/6`.
  When that precision is needed, the honest trade is the gated source-level
  recorder, whose cost is real and measured (`test/bl/build_test.bl` failed two
  runs in three with it live) and which should be compiled in only for an
  investigation, never shipped armed.

  ## Use

      iex> rec = BeamLisp.NifTrace.start("/tmp/nif.log")
      iex> BeamLisp.NifTrace.stop(rec)

  Or from a shell, with no code change at all:

      BEAM_LISP_NIF_TRACE=/tmp/nif.log bl build

  then read the tail of `/tmp/nif.log` after the crash.
  """

  @env "BEAM_LISP_NIF_TRACE"

  @doc """
  Record every call `module` makes into `path`, until `stop/1`.

  `module` defaults to `BeamLisp.LazyMemo`, whose functions are the stubs that
  the native library replaces — tracing them names the NIF about to run.
  Returns a handle to pass to `stop/1`.
  """
  def start(path, module \\ BeamLisp.LazyMemo) when is_binary(path) do
    parent = self()
    ref = make_ref()

    # The tracer OPENS THE FILE, rather than being handed a descriptor. A raw
    # file belongs to the process that opened it — handing it across raises
    # `:not_on_controlling_process` on the first write — and opening it here
    # also means the file exists before the first call is armed, so no message
    # can arrive at a recorder that is not yet listening.
    tracer =
      spawn(fn ->
        {:ok, io} = File.open(path, [:write, :raw, :binary])
        send(parent, {:ready, ref})
        loop(io)
      end)

    receive do
      {:ready, ^ref} -> :ok
    after
      5_000 -> raise "nif trace: tracer did not open #{path}"
    end

    # `:call` turns the trace flag on for every process; `trace_pattern/3`
    # decides which calls actually produce a message, so only `module` is
    # recorded. Order matters: the pattern must be set before the flag, or a
    # call in the gap is reported with nothing to match it against.
    :erlang.trace_pattern({module, :_, :_}, true, [:local])
    :erlang.trace(:all, true, [:call, {:tracer, tracer}])
    :erlang.trace(:existing, true, [:call, {:tracer, tracer}])

    %{path: path, tracer: tracer, module: module}
  end

  @doc """
  Stop recording and close the file.

  FLUSHES first, and that is not a detail: trace messages are delivered to the
  tracer's mailbox asynchronously, so killing it on the way out discards
  everything still queued — which is everything the recorder was asked to
  record. The mailbox is FIFO, so a round-trip sent after the flag is cleared
  can only be answered once every earlier message has been written.

  A crash never gets here. That is the point of the unsynced write: on a clean
  stop the flush is what makes the file complete, and after a SIGSEGV the file
  is whatever reached the page cache, which is what makes it useful.
  """
  def stop(%{module: module, tracer: tracer}) do
    :erlang.trace_pattern({module, :_, :_}, false, [:local])
    :erlang.trace(:all, false, [:call])
    :erlang.trace(:existing, false, [:call])

    ref = make_ref()
    send(tracer, {:close, self(), ref})

    receive do
      {:closed, ^ref} -> :ok
    after
      5_000 -> Process.exit(tracer, :kill)
    end

    :ok
  end

  @doc """
  Trace into `path` when `#{@env}` names one, otherwise do nothing.

  This is the shell entry: `bl` calls it at start-up so a crash can be recorded
  with no code change and no rebuild.
  """
  def start_from_env(module \\ BeamLisp.LazyMemo) do
    case System.get_env(@env) do
      nil -> :off
      "" -> :off
      path -> {:on, start(path, module)}
    end
  end

  @doc "The path `#{@env}` names, or nil."
  def path, do: System.get_env(@env)

  defp loop(io) do
    receive do
      # `:call` reports the ARGUMENTS, not the arity: the payload is
      # `{Module, Function, Args}`. The arity is what a reader wants — the
      # arguments are unbounded and would make the recorder a copy of the
      # workload — so this counts them and drops them.
      {:trace, pid, :call, {module, function, args}} ->
        IO.binwrite(io, [
          Integer.to_string(System.monotonic_time(:microsecond)),
          " ",
          Atom.to_string(function),
          "/",
          Integer.to_string(length(args)),
          " ",
          inspect(module),
          " pid=",
          inspect(pid),
          "\n"
        ])

        loop(io)

      {:close, from, ref} ->
        # A round trip, not a kill: the mailbox is FIFO, so answering this can
        # only happen once every earlier trace message has been written. Killing
        # the tracer instead would discard everything still queued — which is
        # everything the recorder was asked to record.
        File.close(io)
        send(from, {:closed, ref})

      _other ->
        loop(io)
    end
  end
end
