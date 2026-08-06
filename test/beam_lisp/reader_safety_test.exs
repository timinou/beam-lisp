defmodule BeamLisp.ReaderSafetyTest do
  # Deliberately sync: the guard reads its high-water fraction from the global
  # application environment, so these tests must not overlap async readers.
  use ExUnit.Case, async: false

  alias BeamLisp.Reader
  alias BeamLisp.Reader.AtomLimitError

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

  test "guard raises a clean, catchable error when the high-water mark is hit" do
    # fraction 0 ⇒ any sampled token is past the ceiling; interval 1 ⇒ the
    # very first symbol samples.
    with_guard_config!(0.0, 1)

    assert_raise AtomLimitError, ~r/refusing to read "foo".*atom table/, fn ->
      Reader.read_one("foo")
    end
  end

  test "error names the offending keyword and the live atom limit" do
    with_guard_config!(0.0, 1)

    err = assert_raise AtomLimitError, fn -> Reader.read_one(":danger") end
    assert err.message =~ ":danger"
    assert err.message =~ Integer.to_string(:erlang.system_info(:atom_limit))
  end

  test "default config never fires on normal reads" do
    # No env overrides ⇒ 0.9 high-water, interval 256; the live table is far
    # below 90% of the limit, so the whole prelude-style read must pass.
    forms =
      Reader.read_all("""
      (defn foo [x y] (let [a 1 b :kw c (map f [1 2 3])] (+ x (* a y) c)))
      :ok :again
      [a b c] {k v}
      """)

    assert length(forms) == 5
  end

  test "plain literals never count toward the sampling counter" do
    # Integers/floats/strings intern no atoms, so even with interval 1 and a
    # zero ceiling, a read that is all literals must pass untouched.
    with_guard_config!(0.0, 1)

    assert Reader.read_all("42 -7 2.5 \"text\" nil true false") ==
             [42, -7, 2.5, "text", nil, true, false]
  end

  test "sampling counter does not leak between reads" do
    with_guard_config!(0.0, 5)

    # 4 tokens < interval 5 → no sample, no error.
    Reader.read_all("a b c d")

    # A fresh 1-token read must NOT fire: if the counter had leaked it would
    # sit at 4 and this token would sample at 5 and trip the guard.
    Reader.read_all("e")

    # A 5-token read fires on its 5th token.
    assert_raise AtomLimitError, fn -> Reader.read_all("e f g h i") end
  end
end
