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

  # The port's read deadline — the BACKSTOP, not the policy. The pool arms z3's
  # OWN ceiling (priv/std/z3pool.bl, `z3-timeout-ms`) at every lease, so a hard
  # query is answered `unknown` by the solver and never reaches this. This one
  # fires when z3 ignores its own ceiling, when the port is driven directly (the
  # tests do), or when a caller arms a ceiling ABOVE it — so a caller who wants
  # to wait longer than this for one answer must move this too, with
  # BL_Z3_READ_TIMEOUT. A raise here is a real bug, and the honest report.
  #
  # ORDERING, in one place: z3's :timeout  <  this  <  the caller's `call`
  # timeout (z3pool/call-timeout-ms). Measured before the ordering existed: a
  # query needing 6s killed its caller on the transport's compiled-in 5000ms
  # default, and one needing 10s died HERE with an empty accumulator — no
  # verdict, no diagnosis (FUP-057).
  @default_read_timeout 20_000

  @doc """
  A positive integer from the environment, or `default`.

  ONE rule for every bound in this path: a missing, non-numeric or non-positive
  value falls back rather than disarming the deadline it exists to enforce.
  """
  def env_ms(name, default) do
    case System.get_env(name) do
      nil ->
        default

      raw ->
        case Integer.parse(raw) do
          {n, ""} when n > 0 -> n
          _ -> default
        end
    end
  end

  @doc """
  How long a single read from z3 may take, in ms.

  `BL_Z3_READ_TIMEOUT` moves it; a missing, non-numeric or non-positive value
  falls back to the default rather than disarming the read.
  """
  def read_timeout, do: env_ms("BL_Z3_READ_TIMEOUT", @default_read_timeout)

  # z3 answers `(echo "…")` with the string alone (verified against the pinned
  # binary), which makes it a reliable sync marker: a command is acknowledged on
  # its own terms, instead of hoping the next check-sat surfaces its error.
  @marker "~~bl-ok~~"

  @doc """
  Start z3 and return its port.

  The driver is FUNCTIONS, not a process, and that is deliberate: ports deliver
  their replies to the mailbox of the process that OWNS them, so whoever owns the
  port must be whoever calls the functions below. Called from a beam-lisp
  `defserver` (see priv/std/z3pool.bl), that gives structural serialization — a
  gen_server answers one call at a time — with no lock anywhere.
  """
  def open do
    case open_port() do
      {:ok, port} -> port
      {:error, reason} -> raise reason
    end
  end

  def close(port) do
    if alive?(port), do: Port.close(port)
    :ok
  end

  @doc """
  Start a z3 process. Called ONLY by the owner (`BeamLisp.Z3.Solver`), which
  keeps the port for its whole life and serializes every conversation on it.

  The solver is resolved at EXACTLY one place — `priv/z3/bin/z3`, the pinned
  binary fetched by `mix bl.z3.fetch` — never the PATH: what proves your rules
  is the artifact the repo pinned, not whatever a shell happens to resolve. The
  error names the remedy when it is absent.
  """
  def open_port do
    case resolve_exe() do
      nil -> {:error, missing_solver_message()}
      exe -> {:ok, Port.open({:spawn_executable, exe}, [:binary, :stream, :use_stdio, args: ["-in"]])}
    end
  end

  defp missing_solver_message do
    """
    bundled z3 not found. Looked (in order) at:
    #{candidate_paths() |> Enum.map(&("  - " <> &1)) |> Enum.join("\n")}
    run: mix bl.z3.fetch   (or set BEAM_LISP_Z3=/path/to/z3)\
    """
  end

  @doc """
  True while the solver process behind `port` is reachable.

  A port dies with the process that OPENED it, so a memoized port can
  outlive its owner — the server that answered the first query. A caller
  that caches a port must ask this before reusing it: `Port.command/2` on a
  closed port raises badarg, which reaches the client as a bare
  `ArgumentError: argument error`.
  """
  def alive?(port), do: is_port(port) and Port.info(port) != nil
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

  RUNS IN THE PORT'S OWNER: the reads below arrive in the caller's mailbox, so
  the owner is the only process that may call this.
  """
  def check(port, smt, model? \\ false), do: raw_check(port, smt, model?)

  @doc """

  `unknown` means the question was not decided, and the two ways that happens
  want OPPOSITE responses: a CEILING (`timeout` / `canceled`) says raise it or
  simplify the query; an INCOMPLETE THEORY says no ceiling will help, and the
  obligation has to stay undecided rather than be retried harder. Measured against
  the pinned binary: a factoring query under `(set-option :timeout 300)` answers
  `timeout` standalone and `canceled` through the pool, and a DECIDED check answers
  the empty string — which is why an absent reason comes back as nil and can never
  be read as a name.

  One extra round trip, on the undecided path only. The reply is the RAW z3
  string here; naming it is the language's job (`oracle/verdict`).
  """
  def raw_reason(port, status, rest) when status == "unknown" do
    Port.command(port, "(get-info :reason-unknown)\n")
    read_sexp(port, rest) |> extract_reason()
  end

  def raw_reason(_port, _status, _rest), do: nil

  # `(:reason-unknown "timeout")` → "timeout"; `(:reason-unknown "")` → nil; any
  # other shape → nil, because a caller that cannot read the reason must not be
  # handed a guess.
  @reason_re ~r/^\(:reason-unknown\s+(.*)\)$/s

  defp extract_reason(text) do
    case Regex.run(@reason_re, String.trim(text || "")) do
      [_, inner] ->
        inner =
          inner
          |> String.trim()
          |> String.trim_leading("\"")
          |> String.trim_trailing("\"")

        if inner == "", do: nil, else: inner

      _ ->
        nil
    end
  end



  @doc "The protocol itself. Runs in the OWNER process only."
  def raw_check(port, smt, model? \\ false) do
    # A caller-supplied (check-sat) would make z3 answer TWICE and desync the
    # reader by one answer for every later query on this port — a silent,
    # alternating sat/unsat that looks like a solver bug. Strip it: this
    # function owns the check.
    smt = Regex.replace(~r/^\s*\(check-sat\)\s*$/m, smt, "")
    Port.command(port, "(reset)\n" <> smt <> "(check-sat)\n")

    case read_answer(port, "") do
      {"sat", rest} ->
        if model? do
          Port.command(port, "(get-model)\n")
          %{status: "sat", model: read_sexp(port, rest)}
        else
          %{status: "sat", model: nil}
        end

      {line, rest} ->
        %{status: line, model: nil, why: raw_reason(port, line, rest)}
    end
  end

  # ── a conversation (push/pop, assumptions, unsat cores) ──────────────────

  @doc """
  Send SMT-LIB and wait for z3 to ACKNOWLEDGE it. Anything z3 prints before the
  marker is returned as `:output`; an `(error …)` line comes back as
  `%{ok: false}` rather than desynchronizing the reader.
  """
  def raw_command(port, smt) do
    Port.command(port, smt <> "\n(echo \"" <> @marker <> "\")\n")

    case read_until_marker(port, "", "") do
      {:marker, out} -> %{ok: true, output: out}
      {:error, line, out} -> %{ok: false, error: line, output: out}
    end
  end

  @doc """
  The same check, positional — beam-lisp callers pass `(assume core? model?)` and
  never have to marshal a map across the boundary.
  """
  def raw_check_here3(port, assume, core?, model?) do
    raw_check_here(port, %{assume: assume, core?: core?, model?: model?})
  end

  @doc """
  check-sat in the CURRENT solver state — no reset, so assertions accumulate and
  `push`/`pop` scope them. Options: `:assume` (SMT-LIB literals checked with
  `check-sat-assuming`), `:core?` (return the unsat core — assertions must be
  named and the script must set `:produce-unsat-cores`), `:model?` (return the
  model on sat).
  """
  def raw_check_here(port, opts) do
    assume = Map.get(opts, :assume) || []

    check =
      if assume == [] do
        "(check-sat)\n"
      else
        "(check-sat-assuming (" <> Enum.join(assume, " ") <> "))\n"
      end

    Port.command(port, check)

    case read_answer(port, "") do
      {"unsat", rest} ->
        if Map.get(opts, :core?) do
          Port.command(port, "(get-unsat-core)\n")
          %{status: "unsat", core: read_sexp(port, rest)}
        else
          %{status: "unsat", core: nil}
        end

      {"sat", rest} ->
        if Map.get(opts, :model?) do
          Port.command(port, "(get-model)\n")
          %{status: "sat", core: nil, model: read_sexp(port, rest)}
        else
          %{status: "sat", core: nil}
        end

      {line, rest} ->
        %{status: line, core: nil, why: raw_reason(port, line, rest)}
    end
  end

  @doc """
  One SCOPED question: push, assert the script, check-sat, [get-model], pop — all
  inside one call, against the solver state the caller's conversation already
  built. The prelude is therefore sent once per conversation instead of once per
  question (measured: a push/assert/check/pop question is 96 us at the solver and
  3009 us when the prelude is re-sent after a reset).

  `(get-model)` runs BEFORE the pop — the model of a popped scope is gone — and
  `pop` prints nothing, so the reply stream stays exactly one status (+ model).
  """
  def raw_scoped(port, smt, model? \\ false) do
    Port.command(port, "(push 1)\n" <> smt <> "\n(check-sat)\n")

    case read_answer(port, "") do
      {"unsat", _rest} ->
        Port.command(port, "(pop 1)\n")
        %{status: "unsat", core: nil, model: nil}

      {"sat", rest} ->
        model = if model?, do: (Port.command(port, "(get-model)\n") && read_sexp(port, rest))
        Port.command(port, "(pop 1)\n")
        %{status: "sat", core: nil, model: model}

      {line, rest} ->
        why = raw_reason(port, line, rest)
        Port.command(port, "(pop 1)\n")
        %{status: line, core: nil, model: nil, why: why}
    end
  end

  defp read_until_marker(port, acc, out) do
    lines = String.split(acc, "\n")

    cond do
      Enum.member?(lines, @marker) ->
        {:marker, out}

      Enum.any?(lines, &String.starts_with?(&1, "(error")) ->
        {:error, Enum.find(lines, &String.starts_with?(&1, "(error")), out}

      true ->
        receive do
          {^port, {:data, data}} ->
            keep =
              (acc <> data)
              |> String.split("\n")
              |> Enum.reject(&(&1 == "" or &1 == @marker))
              |> Enum.join("\n")

            read_until_marker(port, acc <> data, keep)
        after
          read_timeout() -> {:error, "timeout waiting for z3 to acknowledge", out}
        end
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
      read_timeout() -> raise "z3 timeout (acc: #{inspect(acc)})"
    end
  end

  defp read_sexp(port, acc) do
    if String.length(acc) > 3 and balanced?(acc) do
      acc
    else
      receive do
        {^port, {:data, data}} -> read_sexp(port, acc <> data)
      after
        read_timeout() -> acc
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
