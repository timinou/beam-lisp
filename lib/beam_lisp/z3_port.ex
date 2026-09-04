defmodule BeamLisp.Z3Port do
  @moduledoc """
  The z3 port driver — the solver is a NATIVE CALL (MVP-C's blessed
  shape): beam-lisp code builds SMT-LIB text and calls `check/1` /
  `check/2`; this module owns the subprocess protocol.

  Protocol lessons (from research/p13a_smt + p13d_rule_proofs):
    * `(reset)` per query — a long-lived z3 accumulates assertions.
    * Answers are found by scanning LINES for sat/unsat/unknown/error —
      z3 may print `(error …)` or warnings before the answer.
    * Model bytes may share the `sat` chunk — the model reader is fed
      the remainder, not a fresh receive.
    * A model is complete when its parens balance after a non-empty
      body.
  """

  @timeout 10_000

  @doc """
  Start z3 reading SMT-LIB from stdin.

  The solver is resolved at EXACTLY one place — `priv/z3/bin/z3`, the
  pinned binary fetched by `mix beam_lisp.z3.fetch` — never the PATH:
  what proves your rules is the artifact the repo pinned, not whatever
  a shell happens to resolve. Raises with the remedy when absent.
  """
  def open do
    exe = resolve_exe()

    unless exe && File.exists?(exe) do
      raise """
      bundled z3 not found. Looked (in order) at:
      #{candidate_paths() |> Enum.map(&("  - " <> &1)) |> Enum.join("\n")}
      run: mix beam_lisp.z3.fetch   (or set BEAM_LISP_Z3=/path/to/z3)\
      """
    end

    Port.open({:spawn_executable, exe}, [:binary, :stream, :use_stdio, args: ["-in"]])
  end

  # Resolve the PINNED z3 artifact across packaging tiers — never the system
  # PATH. Three candidates, first that exists wins:
  #   1. BEAM_LISP_Z3 env — an explicit pin (release/CI points it at its artifact)
  #   2. :code.priv_dir/z3/bin/z3 — the mix / OTP-release layout, where priv_dir
  #      is a real directory the fetch task populated
  #   3. <cwd>/priv/z3/bin/z3 — the ESCRIPT tier: `bl` is a single archive file,
  #      so priv_dir resolves to a pseudo-path INSIDE it that can hold no 34MB
  #      NIF; the pinned binary still lives in the checkout's priv/, and `bl` is
  #      run from the repo root. This is a repo artifact, not a PATH lookup.
  # All three name the SAME pinned binary the repo controls — the "what proves
  # your rules is the artifact the repo pinned" invariant holds across tiers.
  defp resolve_exe do
    Enum.find(candidate_paths(), &File.exists?/1)
  end

  defp candidate_paths do
    exe = if match?({:win32, _}, :os.type()), do: "z3.exe", else: "z3"
    # Three candidates, first that exists wins (see the doc above).
    # priv uses Tiers.priv_root/0, NOT :code.priv_dir: inside an escript the
    # code path answers with a path INSIDE the archive, which is not a
    # directory on disk — Tiers.priv_root falls back to the checkout's priv/,
    # the truth there as everywhere else.
    env = System.get_env("BEAM_LISP_Z3")
    priv = Path.join([BeamLisp.Tiers.priv_root(), "z3", "bin", exe])
    cwd = Path.join([File.cwd!(), "priv", "z3", "bin", exe])
    (if(env, do: [env], else: []) ++ [priv, cwd]) |> Enum.uniq()
  end

  @doc """
  Reset, assert `smt`, check-sat. Returns `%{status:, model:}` where
  status is "sat" | "unsat" | "unknown" | "error"; model is the
  `(get-model)` text when `model?: true` and status is "sat".
  """
  def check(port, smt, model? \\ false) do
    Port.command(port, "(reset)\n" <> smt <> "(check-sat)\n")

    case read_answer(port, "") do
      {"sat", rest} ->
        if model? do
          Port.command(port, "(get-model)\n")
          %{status: "sat", model: read_model(port, rest)}
        else
          %{status: "sat", model: nil}
        end

      {line, _} ->
        %{status: line, model: nil}
    end
  end

  defp read_answer(port, acc) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data
        lines = String.split(acc, "\n")

        case Enum.find_index(lines, &(&1 in ["sat", "unsat", "unknown", "error"])) do
          nil ->
            read_answer(port, acc)

          idx ->
            rest = lines |> Enum.drop(idx + 1) |> Enum.join("\n")
            {Enum.at(lines, idx), rest}
        end
    after
      @timeout -> raise "z3 timeout (acc: #{inspect(acc)})"
    end
  end

  defp read_model(port, acc) do
    if String.length(acc) > 3 and balanced?(acc) do
      acc
    else
      receive do
        {^port, {:data, data}} -> read_model(port, acc <> data)
      after
        @timeout -> acc
      end
    end
  end

  defp balanced?(s) do
    s
    |> String.graphemes()
    |> Enum.reduce(0, fn
      "(", n -> n + 1
      ")", n -> n - 1
      _, n -> n
    end) == 0
  end
end
