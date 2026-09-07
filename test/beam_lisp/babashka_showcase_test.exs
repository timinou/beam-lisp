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

  test "set union retains variadic conj when the core root is reseeded" do
    BeamLisp.Loader.ensure_loaded("clojure.set")
    original = BeamLisp.Env.fetch!("core", "conj")
    try do
      BeamLisp.Env.intern("core", "conj", BeamLisp.RT.multi_fn(%{1 => &BeamLisp.RT.conj/1, 2 => &BeamLisp.RT.conj/2}))
      value = BeamLisp.eval(~S|(clojure.set/union #{1} #{2} #{3})|)
      assert BeamLisp.Set.to_list(value) |> Enum.sort() == [1, 2, 3]
    after
      BeamLisp.Env.intern("core", "conj", original)
    end
  end

  describe "the runnable guidebook" do
    test "docs/babashka-on-the-beam.bl.md executes every code cell" do
      # A literate `.bl.md` doc: run_file reads its beam-lisp code cells and
      # evaluates them. This pins that the whole guidebook runs end to end and
      # that its key computations are right — so the doc cannot rot.
      out =
        ExUnit.CaptureIO.capture_io(fn ->
          BeamLisp.run_file("docs/babashka-on-the-beam.bl.md")
        end)

      # a spread of sections, and the final marker proving it reached the end
      assert out =~ "hell0 w0rld"
      assert out =~ "safety — (inc 1) stays DATA: (inc 1)"
      assert out =~ "south: 550"
      assert out =~ "north: 250"
      assert out =~ "everything above executed"
    end
  end
end
