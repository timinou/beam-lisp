defmodule BeamLisp.ExamplesTest do
  use ExUnit.Case, async: false

  # The examples are executable documentation; keep them honest.
  # A crash fails the test; return values vary by file.
  #
  # `**` so examples in SUBDIRECTORIES are covered too. The datom
  # tutorials live in examples/datom/ and were unchecked under a
  # single-level glob — which matters, because writing them found three
  # real defects: a tutorial uses an API the way its NAME invites rather
  # than the way its implementer remembers.
  for file <- Path.wildcard("examples/**/*.bl") do
    test "#{file} runs clean" do
      _ = BeamLisp.run_file(unquote(file))
    end
  end
end
