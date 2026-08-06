defmodule BeamLisp.ExamplesTest do
  use ExUnit.Case, async: false

  # The examples are executable documentation; keep them honest.
  # A crash fails the test; return values vary by file.
  for file <- Path.wildcard("examples/*.bl") do
    test "#{file} runs clean" do
      _ = BeamLisp.run_file(unquote(file))
    end
  end
end
