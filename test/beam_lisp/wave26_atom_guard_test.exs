defmodule BeamLisp.Wave26AtomGuardTest do
  # The reader has refused to intern past a high-water mark since an
  # earlier wave, but the reader was never the only layer that interns:
  # the compiler turns keyword forms into atoms too. A guard on one of
  # two doors is not a guard, so these tests are specifically about the
  # door that was open.
  #
  # Deliberately sync: the guard reads its configuration from the global
  # application environment.
  use ExUnit.Case, async: false

  alias BeamLisp.AtomGuard

  setup do
    on_exit(fn ->
      Application.delete_env(:beam_lisp, :atom_high_water_fraction)
      Application.delete_env(:beam_lisp, :atom_check_interval)
    end)

    :ok
  end

  defp with_guard_config!(fraction, interval) do
    Application.put_env(:beam_lisp, :atom_high_water_fraction, fraction)
    Application.put_env(:beam_lisp, :atom_check_interval, interval)
  end

  describe "the shared guard" do
    test "refuses a new name when the table is at its high-water mark" do
      # fraction 0.0 ⇒ any live table is already past the ceiling.
      with_guard_config!(0.0, 1)

      err =
        assert_raise AtomGuard.LimitError, fn ->
          AtomGuard.to_atom("wave26_never_before_seen_#{System.unique_integer([:positive])}")
        end

      assert err.message =~ "refusing to intern"
      assert err.message =~ "aborts the whole VM"
    end

    test "an already-interned name costs nothing and is never refused" do
      # :wave26_existing exists from this very line, so the guard must
      # let it through even with the ceiling on the floor: re-reading a
      # name the VM already holds cannot grow the table, and refusing it
      # would break every REPL re-evaluation.
      _ = :wave26_existing
      with_guard_config!(0.0, 1)

      assert AtomGuard.to_atom("wave26_existing") == :wave26_existing
    end

    test "samples only every :atom_check_interval new names" do
      # Interval 3 with the ceiling on the floor: the first two novel
      # names pass unsampled, the third trips the check. This is the
      # cost/accuracy trade the guard makes explicit.
      with_guard_config!(0.0, 3)
      tag = System.unique_integer([:positive])

      assert is_atom(AtomGuard.to_atom("wave26_a_#{tag}"))
      assert is_atom(AtomGuard.to_atom("wave26_b_#{tag}"))

      assert_raise AtomGuard.LimitError, fn -> AtomGuard.to_atom("wave26_c_#{tag}") end
    end

    test "a sane ceiling lets ordinary interning proceed" do
      with_guard_config!(0.9999, 1)
      tag = System.unique_integer([:positive])

      assert AtomGuard.to_atom("wave26_ok_#{tag}") == String.to_atom("wave26_ok_#{tag}")
    end

    test "configuration is clamped rather than trusted" do
      Application.put_env(:beam_lisp, :atom_high_water_fraction, 5.0)
      assert AtomGuard.high_water_fraction() == 1.0

      Application.put_env(:beam_lisp, :atom_high_water_fraction, -1.0)
      assert AtomGuard.high_water_fraction() == 0.0

      Application.put_env(:beam_lisp, :atom_check_interval, 0)
      assert AtomGuard.check_interval() == 1

      Application.put_env(:beam_lisp, :atom_check_interval, :nonsense)
      assert AtomGuard.check_interval() == 256
    end
  end

  describe "the compile path" do
    setup do
      BeamLisp.init()
      :ok
    end

    test "compiling a novel keyword goes through the guard" do
      # This is the hole the earlier wave left open: source can reach the
      # compiler without passing the reader's counter (a macro building
      # keyword forms, or any caller compiling forms directly), and the
      # compiler interned them unguarded.
      tag = System.unique_integer([:positive])
      form = {:keyword, "wave26_compiled_#{tag}"}

      with_guard_config!(0.0, 1)

      assert_raise AtomGuard.LimitError, fn ->
        BeamLisp.Compiler.compile(form, BeamLisp.Compiler.new_env("wave26"))
      end
    end

    test "a keyword the VM already holds still compiles at any ceiling" do
      _ = :wave26_known_keyword
      with_guard_config!(0.0, 1)

      assert BeamLisp.Compiler.compile(
               {:keyword, "wave26_known_keyword"},
               BeamLisp.Compiler.new_env("wave26")
             ) == :wave26_known_keyword
    end

    test "ordinary evaluation is unaffected by the guard being present" do
      # The guard must be invisible in normal use — if it were not, every
      # program would pay for a hazard that only hostile input creates.
      assert BeamLisp.eval("(:b {:a 1 :b 2})") == 2
      assert BeamLisp.eval("(count [:x :y :z])") == 3
    end
  end
end
