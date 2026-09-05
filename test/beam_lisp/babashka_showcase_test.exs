defmodule BeamLisp.BabashkaShowcaseTest do
  # End-to-end proof that the Babashka showcase scripts under
  # examples/babashka/ RUN as real scripts and print the RIGHT output. Each is
  # invoked exactly as `bl run FILE -- args` would: argv bound via
  # `BeamLisp.with_argv/2`, the file evaluated via `BeamLisp.run_file/1` (which
  # strips the shebang and binds `*command-line-args*`). We capture stdout and
  # assert the computed report — so this pins the compat layer's behavior end to
  # end, not just "loads clean" (the examples_test/ward runner covers that).
  use ExUnit.Case, async: false

  setup_all do
    BeamLisp.init()
    :ok
  end

  # Run a showcase script with `args` bound as argv, returning its stdout.
  defp run(script, args) do
    path = Path.join(["examples", "babashka", script])

    ExUnit.CaptureIO.capture_io(fn ->
      BeamLisp.with_argv(args, fn -> BeamLisp.run_file(path) end)
    end)
  end

  describe "wordfreq.bl" do
    test "reports the top words of a file, ranked by frequency" do
      tmp = Path.join(System.tmp_dir!(), "bl_showcase_wf.txt")
      File.write!(tmp, "the cat the dog the cat bird")
      out = run("wordfreq.bl", [tmp, "3"])

      assert out =~ "Top 3 words"
      # ranked: the(3), cat(2), then a 1.  The 3 and 2 lead.
      lines = out |> String.split("\n") |> Enum.map(&String.trim/1)
      assert Enum.at(lines, 1) == "3  the"
      assert Enum.at(lines, 2) == "2  cat"
    after
      File.rm(Path.join(System.tmp_dir!(), "bl_showcase_wf.txt"))
    end

    test "self-demos on no args (bundled sample)" do
      out = run("wordfreq.bl", [])
      assert out =~ "bundled sample"
      assert out =~ "the"
    end
  end

  describe "edn_report.bl" do
    test "summarizes an EDN file of people" do
      tmp = Path.join(System.tmp_dir!(), "bl_showcase_people.edn")

      File.write!(tmp, """
      [{:name "Ada" :age 30 :roles [:admin :dev]}
       {:name "Bob" :age 50 :roles [:dev]}]
      """)

      out = run("edn_report.bl", [tmp])
      assert out =~ "People:  2"
      assert out =~ "Roles:   admin, dev"
      assert out =~ "Avg age: 40"
      assert out =~ "admin: Ada"
      assert out =~ "dev: Ada, Bob"
    after
      File.rm(Path.join(System.tmp_dir!(), "bl_showcase_people.edn"))
    end

    test "self-demos on no args (bundled sample of 4 people)" do
      out = run("edn_report.bl", [])
      assert out =~ "bundled sample"
      assert out =~ "People:  4"
    end
  end

  describe "loc.bl" do
    test "counts lines of code under a directory, grouped by extension" do
      out = run("loc.bl", ["priv/compat", "**/*.bl"])
      assert out =~ "LOC under priv/compat"
      assert out =~ "bl"
      assert out =~ "TOTAL"
      # the compat layer is many files and hundreds of lines
      assert out =~ ~r/bl\s+\d+\s+\d+/
    end
  end
end
