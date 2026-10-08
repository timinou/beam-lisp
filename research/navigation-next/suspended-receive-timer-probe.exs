defmodule SuspendedSleepProbe do
  def wait(pid, deadline) do
    case Process.info(pid, :status) do
      {:status, :waiting} -> :ok
      _ -> if System.monotonic_time(:millisecond) < deadline, do: wait(pid, deadline), else: :miss
    end
  end
  def run(kind) do
    parent = self()
    Enum.reduce_while(1..500, 0, fn n, _ ->
      pid = spawn(fn ->
        case kind do
          :dynamic -> Process.sleep(1)
          :constant -> receive do after 1 -> :ok end
          :message ->
            ticket = :erlang.start_timer(1, self(), :retry)
            receive do {:timeout, ^ticket, :retry} -> :ok end
        end
        send(parent, {:done, self()})
      end)
      case wait(pid, System.monotonic_time(:millisecond) + 100) do
        :ok ->
          try do
            :erlang.suspend_process(pid)
            Process.sleep(3)
            :erlang.resume_process(pid)
            receive do
              {:done, ^pid} -> {:cont, n}
            after
              100 ->
                IO.inspect({:stalled, kind, n, Process.info(pid, [:status, :reductions, :current_stacktrace])})
                send(pid, :probe_wakeup)
                receive do
                  {:done, ^pid} -> IO.inspect({:wakeup_recovered, kind, n})
                after
                  100 -> IO.inspect({:wakeup_still_stalled, kind, n})
                end
                {:halt, n}
            end
          catch
            :error, :badarg -> {:cont, n}
          after
            Process.exit(pid, :kill)
          end
        _ -> Process.exit(pid, :kill); {:cont, n}
      end
    end) |> IO.inspect(label: "completed #{kind}")
  end
end
IO.inspect({System.otp_release(), System.version()}, label: "runtime")
SuspendedSleepProbe.run(:dynamic)
SuspendedSleepProbe.run(:constant)

SuspendedSleepProbe.run(:message)
