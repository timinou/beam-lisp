defmodule BeamLisp.Wave12TestPortTest do
  # Ports clojure.test's core so beam-lisp can carry its own test
  # suite. Exercises the Elixir-side entry points directly (never a
  # recursive `mix` invocation — that would deadlock on the build
  # lock); the non-zero exit path is verified in /tmp scratch runs.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @dir "/tmp/beam_lisp_wave12_port"

  setup_all do
    File.mkdir_p!(@dir)
    :ok
  end

  defp write(name, content), do: File.write!(Path.join(@dir, name), content)
  defp path(name), do: Path.join(@dir, name)

  # capture_io returns only the captured string; the run's return value
  # (the totals map) travels back over a message to the test process.
  defp run_and_capture(name) do
    output =
      capture_io(fn ->
        send(self(), {:suite, BeamLisp.TestRT.run_suite([path(name)])})
      end)

    totals =
      receive do
        {:suite, t} -> t
      end

    {output, totals}
  end

  setup do
    # run_suite runs every registered namespace (:all); clear the
    # registry first so each test asserts only its own file's totals.
    BeamLisp.TestRT.clear_registry()
    :ok
  end

  test "a passing suite returns green totals" do
    write(
      "passing.bl",
      """
      (ns port.passing)

      (deftest arithmetic
        (is (= (+ 1 2) 3))
        (is (= (* 6 7) 42)))

      (deftest collections
        (testing "map"
          (is (= (map inc [1 2]) '(2 3))))
        (are [x y] (= x y) 1 1 2 2))
      """
    )

    {output, totals} = run_and_capture("passing.bl")

    assert totals.tests == 2
    assert totals.pass == 5
    assert totals.fail == 0
    assert totals.error == 0
    assert BeamLisp.TestRT.passed?(totals)
    assert output =~ "Testing port.passing"
    assert output =~ "Ran 2 tests containing 5 assertions."
    assert output =~ "0 failures, 0 errors."
  end

  test "a failing suite reports detail and red totals" do
    write(
      "failing.bl",
      """
      (ns port.failing)

      (deftest eq-mismatch
        (testing "comparison"
          (is (= 1 2))))

      (deftest error-inside-is
        (is (= (throw (ex-info "boom" {:code 9})) nil)))
      """
    )

    {output, totals} = run_and_capture("failing.bl")

    assert totals.fail == 1
    assert totals.error == 1
    assert totals.pass == 0
    refute BeamLisp.TestRT.passed?(totals)

    # the `=` special case reports the two sides separately
    assert output =~ "FAIL in (port.failing)"
    assert output =~ "comparison"
    assert output =~ "expected: 1"
    assert output =~ "actual: 2"

    assert output =~ "ERROR in (port.failing)"
    assert output =~ "expected: (= (throw (ex-info \"boom\" {:code 9})) nil)"
    assert output =~ "actual: boom"
    assert output =~ "1 failures, 1 errors."
  end

  test "the mix task exits normally on a green suite" do
    write("green.bl", "(ns port.green)\n(deftest ok (is (= 2 2)))\n")
    output = capture_io(fn -> BeamLisp.TestRT.cli([path("green.bl")]) end)
    assert output =~ "0 failures, 0 errors."
  end

  test "redefining a test replaces it rather than duplicating" do
    write(
      "redefine.bl",
      """
      (ns port.redefine)
      (deftest t (is (= 1 1)))
      (deftest t (is (= 2 2)))
      """
    )

    {_, totals} = run_and_capture("redefine.bl")

    # one deftest of that name, redefined once: a single run, one pass
    assert totals.tests == 1
    assert totals.pass == 1
  end
end
