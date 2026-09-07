defmodule BeamLisp.Wave23LazySeqTest do
  use ExUnit.Case, async: false

  alias BeamLisp.{LazyMemo, LazySeq, Vector}

  setup do
    BeamLisp.init()
    :ok
  end

  defp eval(source), do: BeamLisp.eval(source)

  defp await_waiter_registered(lazy, remaining \\ 10_000)
  defp await_waiter_registered(_lazy, 0), do: flunk("waiter did not register")

  defp await_waiter_registered(lazy, remaining) do
    case LazySeq.memo_state(lazy) do
      {:running, _thunk, _owner, _attempt, [_ | _]} ->
        :ok

      _ ->
        :erlang.yield()
        await_waiter_registered(lazy, remaining - 1)
    end
  end

  defp assert_stats_converge(predicate, remaining \\ 100_000)
  defp assert_stats_converge(_predicate, 0), do: flunk("native memo stats did not converge")

  defp assert_stats_converge(predicate, remaining) do
    :erlang.garbage_collect()
    stats = LazyMemo.stats()

    if predicate.(stats) do
      :ok
    else
      :erlang.yield()
      assert_stats_converge(predicate, remaining - 1)
    end
  end

  describe "lazy force state machine" do
    test "completed values survive pressure and new attempts are rejected before effects" do
      old_budget = Application.get_env(:beam_lisp, :lazy_cache_budget_bytes)

      on_exit(fn ->
        if old_budget == nil do
          Application.delete_env(:beam_lisp, :lazy_cache_budget_bytes)
        else
          Application.put_env(:beam_lisp, :lazy_cache_budget_bytes, old_budget)
        end
      end)

      counter = :counters.new(1, [])

      lazy =
        LazySeq.new(fn ->
          :counters.add(counter, 1, 1)
          :value
        end)

      assert LazySeq.force(lazy) == :value
      Application.put_env(:beam_lisp, :lazy_cache_budget_bytes, 0)
      assert LazySeq.force(lazy) == :value
      assert :counters.get(counter, 1) == 1

      rejected =
        LazySeq.new(fn ->
          :counters.add(counter, 1, 1)
          :never
        end)

      assert_raise LazySeq.ForceError, ~r/lazy_cache_budget_exceeded/, fn ->
        LazySeq.force(rejected)
      end

      assert :counters.get(counter, 1) == 1
    end

    test "concurrent callers share one attempt while another node progresses" do
      parent = self()
      counter = :counters.new(1, [])

      lazy =
        LazySeq.new(fn ->
          :counters.add(counter, 1, 1)
          send(parent, {:started, self()})
          receive do: (:release -> :shared)
        end)

      owner = Task.async(fn -> LazySeq.force(lazy) end)
      assert_receive {:started, owner_pid}
      waiter = Task.async(fn -> LazySeq.force(lazy) end)
      await_waiter_registered(lazy)

      assert LazySeq.force(LazySeq.new(fn -> :unrelated end)) == :unrelated
      send(owner_pid, :release)
      assert Task.await(owner) == :shared
      assert Task.await(waiter) == :shared
      assert :counters.get(counter, 1) == 1
    end

    test "failed attempt reaches waiters and a later explicit force retries" do
      parent = self()
      counter = :counters.new(1, [])

      lazy =
        LazySeq.new(fn ->
          :counters.add(counter, 1, 1)
          attempt = :counters.get(counter, 1)
          send(parent, {:attempt_started, self(), attempt})
          receive do: (:release -> :ok)
          if attempt == 1, do: raise("known failure"), else: :recovered
        end)

      capture = fn ->
        try do
          {:ok, LazySeq.force(lazy)}
        rescue
          e -> {:error, Exception.message(e)}
        end
      end

      owner = Task.async(capture)
      assert_receive {:attempt_started, owner_pid, 1}
      waiter = Task.async(capture)
      await_waiter_registered(lazy)
      send(owner_pid, :release)
      assert Task.await(owner) == {:error, "known failure"}
      assert Task.await(waiter) == {:error, "known failure"}

      retry = Task.async(capture)
      assert_receive {:attempt_started, retry_pid, 2}
      send(retry_pid, :release)
      assert Task.await(retry) == {:ok, :recovered}
      assert LazySeq.force(lazy) == :recovered
      assert :counters.get(counter, 1) == 2
    end

    test "recursive force fails immediately" do
      holder = Agent.start_link(fn -> nil end) |> elem(1)
      lazy = LazySeq.new(fn -> holder |> Agent.get(& &1) |> LazySeq.force() end)
      Agent.update(holder, fn _ -> lazy end)

      assert_raise LazySeq.ForceError, ~r/recursive_force/, fn -> LazySeq.force(lazy) end
    end

    test "owner death is terminal and never replays the thunk" do
      parent = self()
      counter = :counters.new(1, [])

      lazy =
        LazySeq.new(fn ->
          :counters.add(counter, 1, 1)
          send(parent, {:owner_started, self()})
          receive do: (:never -> :value)
        end)

      owner = Task.async(fn -> LazySeq.force(lazy) end)
      assert_receive {:owner_started, owner_pid}

      waiter =
        Task.async(fn ->
          try do
            LazySeq.force(lazy)
          rescue
            e in LazySeq.ForceError -> e.reason
          end
        end)

      await_waiter_registered(lazy)
      Process.unlink(owner.pid)
      Process.exit(owner_pid, :kill)
      assert {:force_owner_lost, ^owner_pid, _attempt} = Task.await(waiter)
      assert_raise LazySeq.ForceError, ~r/force_owner_lost/, fn -> LazySeq.force(lazy) end
      assert :counters.get(counter, 1) == 1
      catch_exit(Task.await(owner))
    end

    test "memo survives Loader.Server restart" do
      counter = :counters.new(1, [])

      lazy =
        LazySeq.new(fn ->
          :counters.add(counter, 1, 1)
          :value
        end)

      assert LazySeq.force(lazy) == :value

      loader = Process.whereis(BeamLisp.Loader.Server)
      monitor = Process.monitor(loader)
      Process.unlink(loader)
      Process.exit(loader, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^loader, _}

      assert LazySeq.force(lazy) == :value
      assert :counters.get(counter, 1) == 1
    end

    test "existing-table force progresses while Loader.Server is busy" do
      parent = self()
      lazy = LazySeq.new(fn -> :unrelated_value end)

      blocker =
        Task.async(fn ->
          BeamLisp.Loader.Server.run(fn ->
            send(parent, {:loader_busy, self()})
            receive do: (:release_loader -> :ok)
          end)
        end)

      assert_receive {:loader_busy, loader_pid}
      force = Task.async(fn -> LazySeq.force(lazy) end)
      assert Task.await(force, 1_000) == :unrelated_value
      send(loader_pid, :release_loader)
      assert Task.await(blocker) == :ok
    end

    test "Loader.Server may wait on a worker forcing an existing lazy" do
      parent = self()
      lazy = LazySeq.new(fn -> :value end)

      load =
        Task.async(fn ->
          BeamLisp.Loader.Server.run(fn ->
            worker = Task.async(fn -> LazySeq.force(lazy) end)
            send(parent, :loader_waiting_on_force)
            Task.await(worker, 1_000)
          end)
        end)

      assert_receive :loader_waiting_on_force
      assert Task.await(load, 1_000) == :value
    end

    test "direct and indirect retained-state cycles become terminal" do
      {:ok, direct_holder} = Agent.start_link(fn -> nil end)
      direct = LazySeq.new(fn -> Agent.get(direct_holder, & &1) end)
      Agent.update(direct_holder, fn _ -> direct end)
      assert_raise LazySeq.ForceError, ~r/cyclic_memo/, fn -> LazySeq.force(direct) end
      assert {:terminal, :cyclic_memo} = LazySeq.memo_state(direct)

      {:ok, holder} = Agent.start_link(fn -> %{} end)
      left = LazySeq.new(fn -> Agent.get(holder, & &1.right) end)
      right = LazySeq.new(fn -> Agent.get(holder, & &1.left) end)
      Agent.update(holder, fn _ -> %{left: left, right: right} end)
      assert LazySeq.force(left) == right
      assert_raise LazySeq.ForceError, ~r/cyclic_memo/, fn -> LazySeq.force(right) end
      assert {:terminal, :cyclic_memo} = LazySeq.memo_state(right)
    end

    test "discarded cells and long chains are reclaimed iteratively" do
      baseline = LazyMemo.stats().live_cells

      task =
        Task.async(fn ->
          Enum.each(1..20_000, fn _ -> LazySeq.new(fn -> :discarded end) end)

          Enum.reduce(1..20_000, LazySeq.new(fn -> nil end), fn n, tail ->
            node = LazySeq.new(fn -> [n | tail] end)
            LazySeq.force(node)
            node
          end)

          :ok
        end)

      assert Task.await(task, 30_000) == :ok

      assert_stats_converge(fn stats ->
        stats.live_cells <= baseline and stats.pending_reclaims == 0
      end)
    end

    test "copies and closure captures retain resources while a live value remains usable" do
      baseline = LazyMemo.stats().live_cells
      child = LazySeq.new(fn -> :child end)
      copy = child
      captured = fn -> child end

      parent =
        LazySeq.new(fn ->
          %{copy: copy, captured: captured, tuple: {child}, improper: [child | :tail]}
        end)

      value = LazySeq.force(parent)

      :erlang.garbage_collect()
      assert LazyMemo.stats().live_cells >= baseline + 2
      assert LazySeq.force(value.copy) == :child
      assert LazySeq.force(value.captured.()) == :child
      assert value.tuple == {child}
      assert value.improper == [child | :tail]
    end

    test "force preserves its caller context even when the caller is Loader.Server" do
      parent = self()
      loader_pid = Process.whereis(BeamLisp.Loader.Server)

      lazy =
        LazySeq.new(fn ->
          send(parent, {:thunk_pid, self()})
          :value
        end)

      force = Task.async(fn -> BeamLisp.Loader.Server.run(fn -> LazySeq.force(lazy) end) end)
      assert_receive {:thunk_pid, thunk_pid}
      assert thunk_pid == loader_pid
      assert Task.await(force, 1_000) == :value
    end
  end

  describe "lazy-seq thunk may return a bare LazySeq (wave 23)" do
    test "minimal repro: nested lazy-seq returning another seq via concat" do
      assert eval(
               "(reduce conj [] (concat (lazy-seq (concat (lazy-seq (list 1)) (list 2))) (list 3)))"
             ) == Vector.new([1, 2, 3])
    end

    test "a thunk returning a bare lazy seq at several nesting depths" do
      assert eval("(reduce conj [] (lazy-seq (lazy-seq (lazy-seq (lazy-seq (list 1 2 3))))))") ==
               Vector.new([1, 2, 3])

      assert eval("(first (lazy-seq (lazy-seq (list 42))))") == 42

      assert eval("(reduce conj [] (concat (lazy-seq []) (lazy-seq (list 7))))") ==
               Vector.new([7])
    end

    test "take over an infinite lazy seq realizes only what it needs" do
      assert eval("(take 5 (concat (lazy-seq (map inc (range))) (list 99)))") ==
               [1, 2, 3, 4, 5]

      # The counter proves the infinite seq is not fully forced: map is
      # chunked at 32, so `take 5` realizes exactly one 32-element chunk
      # of the infinite source, never its tail.
      assert eval("(let [n (atom 0)
                      inf (map (fn [x] (swap! n inc) x) (range))]
                  (doall (take 5 (concat (lazy-seq inf) (list 99))))
                  @n)") == 32
    end

    test "thunks returning [], a vector, a set, and nil all normalize" do
      assert eval("(reduce conj [] (lazy-seq []))") == Vector.new([])

      assert eval("(reduce conj [] (concat (lazy-seq [1 2]) (lazy-seq [3])))") ==
               Vector.new([1, 2, 3])

      # A set's member order is unspecified — check membership, not order.
      # The # in a set literal must be split from the { to avoid Elixir's
      # #{ interpolation inside the source string.
      set_result = eval("(reduce conj [] (lazy-seq #" <> "{1 2}))")
      assert set_result |> Vector.to_list() |> Enum.sort() == [1, 2]

      assert eval("(reduce conj [] (concat (lazy-seq nil) (list 5)))") == Vector.new([5])
    end

    test "concat combines lazy and strict inputs in both orders" do
      assert eval("(reduce conj [] (concat (list 1) (lazy-seq (list 2))))") ==
               Vector.new([1, 2])

      assert eval("(reduce conj [] (concat (lazy-seq (list 1)) (list 2)))") ==
               Vector.new([1, 2])
    end
  end
end
