defmodule Mix.Tasks.BeamLisp.Gen.Case do
  @moduledoc """
  Generate the ExUnit case template that makes a beam-lisp app's tests
  async (PLAN-046):

      mix beam_lisp.gen.case MyApp.BlCase --warm my.app my.app.more

  Writes `test/support/bl_case.ex` (override with `--path`) defining
  `MyApp.BlCase`; test modules then adopt it with one line:

      defmodule MyApp.SomeTest do
        use MyApp.BlCase
        # async: true, private env fork per test, warm base image
      end

  Without `--warm`, the case forks `:global` (prelude only) — tests load
  what they need via `BeamLisp.Sandbox.load_ns/1` / `load_file/1`.

  If your app already has a case template with shared helpers, keep it:
  add `use BeamLisp.ExUnitCase, warm: {…}` there instead (the generator
  is for greenfield adoption).
  """

  @shortdoc "Generate a beam-lisp ExUnit case template"

  use Mix.Task

  @impl true
  def run(args) do
    {opts, args} =
      OptionParser.parse!(args,
        strict: [warm: :keep, path: :string],
        aliases: [w: :warm, p: :path]
      )

    module =
      case args do
        [name] -> Module.concat([name])
        _ -> Mix.raise("usage: mix beam_lisp.gen.case MODULE.NAME [--warm NS …] [--path FILE]")
      end

    warm = for {:warm, ns} <- opts, do: ns
    path = Keyword.get(opts, :path, "test/support/bl_case.ex")

    if File.exists?(path), do: Mix.raise("#{path} already exists — refusing to overwrite")

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, template(module, warm))

    Mix.shell().info("""

    Created #{path} (#{inspect(module)}).

    Adopt in a test module:

        defmodule #{Module.concat([module]) |> Module.split() |> Enum.drop(-1) |> then(fn p -> Enum.join(p ++ ["SomeTest"], ".") end)} do
          use #{inspect(module)}

          test "…" do
            # private fork of the #{if warm == [], do: ":global (cold)", else: "warm"} base
          end
        end
    """)
  end

  defp template(module, []) do
    """
    defmodule #{inspect(module)} do
      @moduledoc \"\"\"
      beam-lisp async test case: every test runs in a private fork of
      `:global` (the prelude only). Load what a test needs with
      `BeamLisp.Sandbox.load_ns/1`, `load_file/1`, or `eval/1`.
      \"\"\"

      use ExUnit.CaseTemplate

      using do
        quote do
          use BeamLisp.ExUnitCase
        end
      end
    end
    """
  end

  defp template(module, warm) do
    """
    defmodule #{inspect(module)} do
      @moduledoc \"\"\"
      beam-lisp async test case: a warm base image holding
      #{Enum.map_join(warm, ", ", &inspect/1)} is built once per VM;
      every test runs in a private zero-copy fork of it
      (`async: true` is on). A test's defs never leak.
      \"\"\"

      use ExUnit.CaseTemplate

      using do
        quote do
          use BeamLisp.ExUnitCase, warm: {#{inspect(base_name(module))}, #{inspect(warm)}}
        end
      end
    end
    """
  end

  defp base_name(module) do
    module |> Module.split() |> List.first() |> Macro.underscore() |> String.to_atom()
  end
end
