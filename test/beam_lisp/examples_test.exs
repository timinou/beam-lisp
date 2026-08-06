defmodule BeamLisp.ExamplesTest do
  use ExUnit.Case, async: false

  # The examples are executable documentation; keep them honest.
  # Each ends in a println, so a clean run returns :ok.
  for file <- Path.wildcard("examples/*.bl") do
    test "#{file} runs clean" do
      assert BeamLisp.run_file(unquote(file)) == :ok
    end
  end
end
