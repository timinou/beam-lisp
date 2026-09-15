defmodule BeamLisp.ClojureCompatDocsTest do
  @moduledoc """
  The two literate walkthroughs of the Clojure-compat tier run end to end and
  print the answers the JVM printed for the same computations — so the docs
  cannot rot, and the claims in them stay claims.
  """
  use ExUnit.Case, async: false

  setup_all do
    BeamLisp.AOT.boot()
    :ok
  end

  test "docs/exact-decimals.bl.md executes every code cell" do
    out = ExUnit.CaptureIO.capture_io(fn -> BeamLisp.run_file("docs/exact-decimals.bl.md") end)

    assert out =~ "decimal: 0.3M"
    assert out =~ "=   false   ==  true"
    assert out =~ "2.34M 2.36M"
    assert out =~ ":decimal/non-terminating"
    assert out =~ "[33.34M 33.33M 33.33M] → sum 100.00M"
    assert out =~ "[0.15M 0.15M 0.14M 0.14M 0.14M 0.14M 0.14M] → sum 1.00M"
  end

  test "docs/running-clojure-libraries.bl.md loads acme/money.cljc unmodified and agrees with the JVM" do
    BeamLisp.Env.add_search_path("examples/clojure-compat/ledger/src")
    out = ExUnit.CaptureIO.capture_io(fn -> BeamLisp.run_file("docs/running-clojure-libraries.bl.md") end)

    # answers captured from `clojure -M` over the same expressions
    assert out =~ "15.10 EUR"
    assert out =~ "2.34 EUR"
    assert out =~ ~s(["33.34 EUR" "33.33 EUR" "33.33 EUR"])
    assert out =~ ~s(["0.04 USD" "0.01 USD"])
    assert out =~ "currency mismatch"
    assert out =~ "not exact"
    assert out =~ "no Java method .frobnicate in the interop manifest"
  end

  test "examples/clojure-compat/decimal.bl runs and splits a bill exactly" do
    out = ExUnit.CaptureIO.capture_io(fn -> BeamLisp.run_file("examples/clojure-compat/decimal.bl") end)
    assert out =~ "[33.34M 33.33M 33.33M] sum 100.00M"
    assert out =~ ":decimal/inexact-operand"
  end

  test "docs/datahike-on-datom.bl.md drives the datahike.api shim over datom end to end" do
    out = ExUnit.CaptureIO.capture_io(fn -> BeamLisp.run_file("docs/datahike-on-datom.bl.md") end)

    assert out =~ "tx-data datoms: 10"
    assert out =~ "in credit: ([\"Bank\" 250] [\"Cash\" 100])"
    assert out =~ ~r/pull cash: \{.*:account\/name "Cash".*\}/
    assert out =~ ~r/pull cash: \{.*:account\/balance 100.*\}/
    assert out =~ "bank name: Bank balance: 250"
    assert out =~ "accounts now: 3"
    assert out =~ "accounts if applied: 4"
  end

  test "docs/datom-find-specs.bl.md shows every find spec and the :with fix" do
    out = ExUnit.CaptureIO.capture_io(fn -> BeamLisp.run_file("docs/datom-find-specs.bl.md") end)

    assert out =~ "relation:  ([\"Ada\" 100] [\"Grace\" 100] [\"Lin\" 90])"
    assert out =~ "scalar:    90"
    assert out =~ "collection: (\"Ada\" \"Grace\" \"Lin\")"
    assert out =~ "tuple:     [\"Ada\" 100]"
    assert out =~ "sum of distinct pay values:  190"
    assert out =~ "sum of pay per person:       290"
    assert out =~ "pay by dept:  ([\"eng\" 200] [\"sales\" 90])"
    assert out =~ "count by dept: ([\"eng\" 2] [\"sales\" 1])"
  end

  test "docs/datom-bitemporal.bl.md shows valid time as the second axis" do
    out = ExUnit.CaptureIO.capture_io(fn -> BeamLisp.run_file("docs/datom-bitemporal.bl.md") end)

    assert out =~ "price on day 90:   100"
    assert out =~ "price on day 200:  120"
    assert out =~ "price on day 180:  120"
    assert out =~ "price on day 90, still: 100"
    assert out =~ "pulled @day 90:  100"
    assert out =~ "prices true across days 90..200: ([100] [120])"
  end

  test "docs/datom-for-accounting.bl.md exercises decimals, tuple keys and guards" do
    out = ExUnit.CaptureIO.capture_io(fn -> BeamLisp.run_file("docs/datom-for-accounting.bl.md") end)

    assert out =~ "ascending: (\"9.99\" \"100.05\" \"100.50\")"
    assert out =~ "1.0M == 1.00M by value: true"
    assert out =~ "derived key: [100 1]"
    assert out =~ "duplicate (100,1) refused: refused"
    assert out =~ "distinct postings: 2"
    assert out =~ "balanced entry committed: 2"
    assert out =~ "unbalanced entry: refused"
    assert out =~ "batch 2 datoms after refusal: 0"
  end
end
