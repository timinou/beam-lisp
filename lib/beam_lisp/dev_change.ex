defmodule BeamLisp.DevChange do
  @moduledoc """
  Local, hash-guarded source changes for .bl files.

  Candidate workspaces and resource limits reduce accidental damage; they are not
  OS confinement and do not make verification of hostile code safe.
  """
  @journal ".beam-lisp/change-journal"
  @lock ".beam-lisp/change.lock"
  @default_allowlist ["mix", "bl", "elixir", "true", "false"]

  # is_map-ok: a host change descriptor is validated by fields, including struct records.
  def plan(spec) when is_map(spec) do
    with {:ok, root} <- root(spec),
         {:ok, path} <- target(root, get(spec, :target)),
         {:ok, bytes} <- File.read(path),
         :ok <- basis(bytes, get(spec, :expected_hash, get(spec, :basis_hash))),
         {:ok, analysis} <- analyze(bytes),
         {:ok, ns} <- namespace(analysis),
         {:ok, span} <- definition(analysis, ns, get(spec, :selector, get(spec, :definition))),
         {:ok, replacement} <- replacement(spec, span.name),
         {:ok, id} <- edit_id(spec) do
      candidate = binary_part(bytes, 0, span.start) <> replacement <>
        binary_part(bytes, span.stop, byte_size(bytes) - span.stop)

      {:ok, %{version: 2, id: id, workspace: root, target: Path.relative_to(path, root),
        namespace: ns, selector: span.selector, span: Map.drop(span, [:text]), old_bytes: bytes,
        candidate_bytes: candidate, old_hash: hash(bytes), new_hash: hash(candidate),
        replacement: replacement, verification: get(spec, :verification, get(spec, :verify)),
        toolchain: toolchain(), status: :planned}}
    end
  end
  def plan(_), do: {:error, :invalid_spec}

  # is_map-ok: host plan records are checked by valid_plan, not sequence classification.
  def preview(p) when is_map(p) do
    with :ok <- valid_plan(p) do
      {:ok, %{id: p.id, target: p.target, namespace: p.namespace, selector: p.selector,
        span: p.span, old_hash: p.old_hash, new_hash: p.new_hash,
        diff: diff(p.old_bytes, p.candidate_bytes, p.target), diagnostics: []}}
    end
  end
  def preview(_), do: {:error, :invalid_plan}

  def verify(plan, opts \\ [])
  # is_map-ok: host plan records are checked by valid_plan, not sequence classification.
  def verify(p, opts) when is_map(p) do
    runner = Keyword.get(opts, :runner)
    allowlist = Keyword.get(opts, :allowlist, @default_allowlist)

    with :ok <- valid_plan(p),
         {:ok, root} <- root(p),
         {:ok, path} <- target(root, p.target),
         {:ok, current} <- File.read(path),
         :ok <- same(current, p.old_hash),
         {:ok, command} <- descriptor(p.verification, allowlist),
         {:ok, tmp} <- copy_workspace(root) do
      try do
        candidate_path = Path.join(tmp, p.target)
        result =
          with :ok <- atomic(candidate_path, p.candidate_bytes),
               {:ok, run_result} <- run(command, tmp, runner) do
            evidence = evidence(p, command, run_result)

            if run_result.status == :ok do
              with :ok <- persist_evidence(root, evidence), do: {:ok, evidence}
            else
              {:error, {:verification_failed, evidence}}
            end
          end

        result
      after
        File.rm_rf(tmp)
      end
    end
  end
  def verify(_, _), do: {:error, :invalid_plan}

  # is_map-ok: both host records undergo explicit plan and authorization validation.
  def apply!(p, _caller_receipt, auth) when is_map(p) and is_map(auth) do
    with :ok <- valid_plan(p),
         :ok <- authorized(auth, p.id, p.new_hash),
         {:ok, root} <- root(p),
         {:ok, path} <- target(root, p.target),
         {:ok, evidence} <- read_evidence(root, p.id),
         :ok <- verified(evidence, p) do
      lock(root, fn -> apply_locked(p, evidence, path) end)
    end
  end
  def apply!(_, _, _), do: {:error, :invalid_application}

  def receipt(id, workspace) when is_binary(id) do
    with {:ok, root} <- canonical_workspace(workspace),
         {:ok, file} <- journal_file(root, id),
         {:ok, bytes} <- safe_read_journal(root, file),
         {:ok, value} <- Jason.decode(bytes) do
      recover(value, root)
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end
  def receipt(_, _), do: {:error, :invalid_receipt_query}

  def undo!(id, auth, workspace) do
    with {:ok, old} <- receipt(id, workspace),
         :ok <- applied_receipt(old),
         :ok <- authorized(auth, id, val(old, "after_hash")),
         {:ok, root} <- canonical_workspace(workspace),
         {:ok, path} <- target(root, val(old, "target")),
         {:ok, bytes} <- File.read(path),
         :ok <- same(bytes, val(old, "after_hash")),
         {:ok, inverse} <- plan(%{id: id <> ":undo:" <> Integer.to_string(System.system_time(:microsecond)),
           workspace: root, target: val(old, "target"), selector: val(old, "selector"),
           replacement: val(old, "old_form"), expected_hash: hash(bytes),
           verification: val(old, "command_descriptor")}) do
      {:ok, inverse}
    end
  end

  defp apply_locked(p, evidence, path) do
    with {:ok, state} <- existing_state(p) do
      case {state, File.read(path)} do
        {:none, {:ok, bytes}} when bytes == p.old_bytes ->
          with :ok <- ensure_journal(p.workspace),
               {:ok, _} <- journal(p, evidence, :intent),
               :ok <- atomic(path, p.candidate_bytes),
               {:ok, result} <- journal(p, evidence, :applied) do
            {:ok, result}
          end

        {:matching, {:ok, bytes}} when bytes == p.candidate_bytes -> receipt(p.id, p.workspace)
        {:matching, {:ok, bytes}} when bytes == p.old_bytes -> {:error, :recovery_not_applied}
        {:matching, {:ok, _}} -> {:error, :recovery_conflict}
        {_, {:ok, _}} -> {:error, :conflict}
        {_, {:error, reason}} -> {:error, {:read_failed, reason}}
      end
    end
  end

  defp existing_state(p) do
    case receipt(p.id, p.workspace) do
      {:error, :not_found} -> {:ok, :none}
      {:ok, prior} ->
        if val(prior, "target") == p.target and val(prior, "old_hash") == p.old_hash and
             val(prior, "after_hash") == p.new_hash,
          do: {:ok, :matching}, else: {:error, :edit_id_reused}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_plan(%{version: 2} = p) do
    with true <- is_binary(p.id) and p.id != "",
         true <- hash(p.old_bytes) == p.old_hash,
         true <- hash(p.candidate_bytes) == p.new_hash,
         {:ok, analysis} <- analyze(p.old_bytes),
         {:ok, ns} <- namespace(analysis),
         {:ok, span} <- definition(analysis, ns, p.selector),
         true <- ns == p.namespace and Map.drop(span, [:text]) == p.span,
         {:ok, replacement} <- validate_replacement(p.replacement, span.name),
         true <- replacement == p.replacement,
         expected = binary_part(p.old_bytes, 0, span.start) <> replacement <>
           binary_part(p.old_bytes, span.stop, byte_size(p.old_bytes) - span.stop),
         true <- expected == p.candidate_bytes,
         true <- p.toolchain == toolchain() do
      :ok
    else
      _ -> {:error, :invalid_plan}
    end
  end
  defp valid_plan(_), do: {:error, :invalid_plan}

  defp root(spec), do: canonical_workspace(get(spec, :workspace, get(spec, :workspace_root)))
  @doc "Validate an existing workspace directory, refusing symlink components."
  def canonical_workspace(root) when is_binary(root) do
    expanded = Path.expand(root)
    cond do
      not File.dir?(expanded) -> {:error, :invalid_workspace}
      path_has_symlink?(expanded) -> {:error, :symlink_workspace}
      true -> {:ok, expanded}
    end
  end
  def canonical_workspace(_), do: {:error, :missing_workspace}

  defp target(root, name) when is_binary(name) do
    parts = Path.split(name)
    full = Path.join(root, name)
    rel = Path.relative_to(Path.expand(full), root)
    cond do
      name == "" or Path.type(name) == :absolute -> {:error, :invalid_target}
      Enum.member?(parts, "..") or rel == ".." or String.starts_with?(rel, "../") -> {:error, :invalid_target}
      symlink_component?(root, parts) -> {:error, :symlink_target}
      not File.regular?(full) -> {:error, :missing_target}
      Path.extname(name) != ".bl" -> {:error, :unsupported_target}
      true -> {:ok, full}
    end
  end
  defp target(_, _), do: {:error, :missing_target}

  # Strict, non-evaluating lexical scan. Reader macros other than top-level quote/discard
  # are opaque prefixes; malformed delimiters and unterminated strings are refused.
  defp analyze(bytes) do
    case scan(bytes, 0, [], nil, nil, [], false) do
      {:ok, forms} -> {:ok, Enum.reverse(forms)}
      {:error, _} = error -> error
    end
  end

  defp scan(bytes, i, stack, _start, state, acc, _prefixed) when i >= byte_size(bytes) do
    cond do
      state == :string -> {:error, :invalid_source}
      stack != [] -> {:error, :invalid_source}
      true -> {:ok, acc}
    end
  end
  defp scan(bytes, i, stack, start, state, acc, prefixed) do
    c = :binary.at(bytes, i)
    cond do
      state == :comment and c == ?\n -> scan(bytes, i + 1, stack, start, nil, acc, prefixed)
      state == :comment -> scan(bytes, i + 1, stack, start, state, acc, prefixed)
      state == :string and c == ?\\ and i + 1 < byte_size(bytes) -> scan(bytes, i + 2, stack, start, state, acc, prefixed)
      state == :string and c == ?" -> scan(bytes, i + 1, stack, start, nil, acc, prefixed)
      state == :string -> scan(bytes, i + 1, stack, start, state, acc, prefixed)
      c == ?; -> scan(bytes, i + 1, stack, start, :comment, acc, prefixed)
      c == ?" -> scan(bytes, i + 1, stack, start, :string, acc, prefixed)
      stack == [] and c in [?', ?`, ?~] -> scan(bytes, i + 1, stack, start, state, acc, true)
      stack == [] and c == ?# and i + 1 < byte_size(bytes) and :binary.at(bytes, i + 1) == ?_ ->
        scan(bytes, i + 2, stack, start, state, acc, true)
      c in [?(, ?[, ?{] -> scan(bytes, i + 1, [matching(c) | stack], if(stack == [], do: i, else: start), state, acc, prefixed)
      c in [?), ?], ?}] and stack == [] -> {:error, :invalid_source}
      c in [?), ?], ?}] and hd(stack) != c -> {:error, :invalid_source}
      c in [?), ?], ?}] and tl(stack) == [] ->
        text = binary_part(bytes, start, i + 1 - start)
        form = %{start: start, stop: i + 1, text: text, prefixed: prefixed}
        scan(bytes, i + 1, [], nil, state, [form | acc], false)
      c in [?), ?], ?}] -> scan(bytes, i + 1, tl(stack), start, state, acc, prefixed)
      true -> scan(bytes, i + 1, stack, start, state, acc, prefixed)
    end
  end
  defp matching(?(), do: ?)
  defp matching(?[), do: ?]
  defp matching(?{), do: ?}

  defp namespace(forms) do
    hits = Enum.filter(forms, fn f -> not f.prefixed and Regex.match?(~r/^\(\s*ns\s+/, f.text) end)
    case hits do
      [%{text: text}] ->
        case Regex.run(~r/^\(\s*ns\s+([^\s\(\)\[\]\{\}]+)/, text) do
          [_, ns] -> {:ok, ns}
          _ -> {:error, :malformed_namespace}
        end
      [] -> {:error, :missing_namespace}
      _ -> {:error, :ambiguous_namespace}
    end
  end

  defp definition(forms, ns, selector) when is_binary(selector) do
    hits = Enum.flat_map(forms, fn f ->
      case definition_header(f) do
        {:ok, name} when selector == name or selector == ns <> "/" <> name ->
          [Map.merge(f, %{selector: selector, name: name})]
        _ -> []
      end
    end)
    case hits do
      [hit] -> {:ok, hit}
      [] -> {:error, :target_not_found}
      _ -> {:error, :ambiguous_target}
    end
  end
  defp definition(_, _, _), do: {:error, :missing_selector}

  defp definition_header(%{prefixed: false, text: text}) do
    case Regex.run(~r/^\(\s*(?:def|defn)\s+([^\s\(\)\[\]\{\}]+)/s, text) do
      [_, name] -> {:ok, name}
      _ -> :no
    end
  end
  defp definition_header(_), do: :no

  defp replacement(spec, expected_name) do
    case get(spec, :replacement, get(spec, :source)) do
      value when is_binary(value) -> validate_replacement(value, expected_name)
      _ -> {:error, :invalid_replacement}
    end
  end
  defp validate_replacement(value, expected_name) do
    with {:ok, [form]} <- analyze(value),
         {:ok, name} <- definition_header(form),
         true <- name == expected_name and form.start == leading_bytes(value) and
           only_trailing_space?(value, form.stop) do
      {:ok, value}
    else
      _ -> {:error, :invalid_replacement}
    end
  end
  defp leading_bytes(value), do: byte_size(value) - byte_size(String.trim_leading(value))
  defp only_trailing_space?(value, stop), do: String.trim(binary_part(value, stop, byte_size(value) - stop)) == ""

  defp basis(_, nil), do: {:error, :missing_basis_hash}
  defp basis(bytes, expected), do: if(hash(bytes) == expected, do: :ok, else: {:error, :stale_basis})
  defp edit_id(spec) do
    case get(spec, :id, get(spec, :edit_id)) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :missing_edit_id}
    end
  end

  defp copy_workspace(root) do
    tmp = Path.join(System.tmp_dir!(), "beam-lisp-change-#{:erlang.unique_integer([:positive])}")
    with :ok <- File.mkdir(tmp), :ok <- copy_tree(root, tmp), do: {:ok, tmp}
  end
  defp copy_tree(source, dest) do
    with {:ok, names} <- File.ls(source) do
      Enum.reduce_while(names, :ok, fn name, :ok ->
        src = Path.join(source, name)
        dst = Path.join(dest, name)
        case File.lstat(src) do
          {:ok, %{type: :symlink}} -> {:halt, {:error, :symlink_in_workspace}}
          {:ok, %{type: :directory, mode: mode}} ->
            case File.mkdir(dst) do
              :ok ->
                case copy_tree(src, dst) do
                  :ok -> File.chmod(dst, mode) |> then(&{:cont, &1})
                  error -> {:halt, error}
                end
              error -> {:halt, error}
            end
          {:ok, %{type: :regular, mode: mode}} ->
            case File.cp(src, dst) do
              :ok -> File.chmod(dst, mode) |> then(&{:cont, &1})
              error -> {:halt, error}
            end
          {:ok, _} -> {:halt, {:error, :unsupported_workspace_entry}}
          error -> {:halt, error}
        end
      end)
    end
  end

  # is_map-ok: host command records are inspected by fields, not language map operations.
  defp descriptor(d, allowlist) when is_map(d) and is_list(allowlist) do
    argv = get(d, :argv)
    cwd = get(d, :cwd, ".")
    env = get(d, :env, [])
    timeout = get(d, :timeout, 30_000)
    memory_kb = get(d, :memory_kb, 1_048_576)
    if is_list(argv) and argv != [] and Enum.all?(argv, &is_binary/1) and hd(argv) in allowlist and
         safe_relative?(cwd) and is_list(env) and
         Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end) and
         is_integer(timeout) and timeout > 0 and is_integer(memory_kb) and memory_kb > 0,
      do: {:ok, %{argv: argv, cwd: cwd, env: env, timeout: timeout, memory_kb: memory_kb}},
      else: {:error, :command_not_allowlisted}
  end
  defp descriptor(_, _), do: {:error, :missing_verification_command}

  defp run(command, workspace, runner) when is_function(runner, 1) do
    cwd = Path.join(workspace, command.cwd)
    if inside?(cwd, workspace) and File.dir?(cwd), do: safe_runner(runner, Map.put(command, :cwd, cwd)),
      else: {:error, :invalid_command_cwd}
  end
  defp run(command, workspace, nil), do: default_run(command, workspace)
  defp run(_, _, _), do: {:error, :invalid_runner}

  defp safe_runner(runner, command) do
    try do normalize(runner.(command)) catch kind, reason -> {:error, {:runner_failed, {kind, reason}}} end
  end
  defp normalize(:ok), do: {:ok, %{status: :ok, exit_status: 0, output: ""}}
  defp normalize({:ok, output}) when is_binary(output), do: {:ok, %{status: :ok, exit_status: 0, output: output}}
  defp normalize({:error, reason}), do: {:ok, %{status: :error, exit_status: 1, output: inspect(reason)}}
  defp normalize(_), do: {:error, :invalid_runner_result}

  defp default_run(c, workspace) do
    cwd = Path.join(workspace, c.cwd)
    with true <- inside?(cwd, workspace) and File.dir?(cwd),
         executable when is_binary(executable) <- System.find_executable(hd(c.argv)),
         manager when is_binary(manager) <- System.find_executable("systemd-run"),
         control when is_binary(control) <- System.find_executable("systemctl") do
      unit = "bl-change-#{System.unique_integer([:positive])}-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      args = ["--user", "--wait", "--pipe", "--collect", "--quiet", "--unit=#{unit}",
              "--property=MemoryMax=#{c.memory_kb}K", "--property=MemorySwapMax=0",
              "--property=RuntimeMaxSec=#{c.timeout}ms", "--working-directory=#{cwd}"] ++
             Enum.map(c.env, fn {key, value} -> "--setenv=#{key}=#{value}" end) ++
             ["--", executable | tl(c.argv)]
      port = Port.open({:spawn_executable, manager}, [:binary, :exit_status, :stderr_to_stdout, :use_stdio, args: args])
      try do
        collect_port(port, System.monotonic_time(:millisecond) + c.timeout, "")
      after
        # Stop the whole cgroup, including descendants that outlive the command.
        System.cmd(control, ["--user", "stop", unit <> ".service"], stderr_to_stdout: true)
        if Port.info(port) != nil, do: Port.close(port)
      end
    else
      _ -> {:error, :runner_unavailable}
    end
  end
  defp collect_port(port, deadline, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    receive do
      {^port, {:data, data}} when byte_size(output) + byte_size(data) <= 1_048_576 ->
        collect_port(port, deadline, output <> data)
      {^port, {:data, _}} -> {:error, :verification_output_limit}
      {^port, {:exit_status, code}} ->
        {:ok, %{status: if(code == 0, do: :ok, else: :error), exit_status: code, output: output}}
    after
      remaining -> {:error, :verification_timeout}
    end
  end

  defp evidence(p, command, result), do: %{version: 1, edit_id: p.id, basis_hash: p.old_hash,
    candidate_hash: p.new_hash, candidate_size: byte_size(p.candidate_bytes), command_descriptor: command,
    status: if(result.status == :ok, do: :verified, else: :failed), exit_status: result.exit_status,
    output: result.output, toolchain: p.toolchain}

  defp persist_evidence(root, evidence) do
    with :ok <- ensure_journal(root), {:ok, file} <- evidence_file(root, evidence.edit_id),
         :ok <- atomic(file, Jason.encode!(evidence)), do: :ok
  end
  defp read_evidence(root, id) do
    with {:ok, file} <- evidence_file(root, id), {:ok, bytes} <- safe_read_journal(root, file),
         {:ok, evidence} <- Jason.decode(bytes), do: {:ok, evidence}
  end
  defp verified(r, p) do
    with {:ok, expected_command} <- descriptor(p.verification, @default_allowlist) do
      command = val(r, "command_descriptor")
      if val(r, "edit_id") == p.id and val(r, "basis_hash") == p.old_hash and
           val(r, "candidate_hash") == p.new_hash and val(r, "candidate_size") == byte_size(p.candidate_bytes) and
           val(r, "status") in [:verified, "verified"] and val(r, "exit_status") == 0 and
           normalize_json(command) == normalize_json(expected_command) and
           normalize_json(val(r, "toolchain")) == normalize_json(p.toolchain),
        do: :ok, else: {:error, :unverified_candidate}
    else
      _ -> {:error, :unverified_candidate}
    end
  end

  defp authorized(a, id, h), do: if(get(a, :id, get(a, :edit_id)) == id and
    get(a, :candidate_hash, get(a, :new_hash)) == h, do: :ok, else: {:error, :unauthorized})
  defp applied_receipt(r), do: if(val(r, "phase") in [:applied, "applied"], do: :ok, else: {:error, :not_applied})
  defp same(bytes, h), do: if(hash(bytes) == h, do: :ok, else: {:error, :conflict})
  defp hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp toolchain, do: %{elixir: System.version(), otp: List.to_string(:erlang.system_info(:otp_release))}
  defp normalize_json(value), do: value |> Jason.encode!() |> Jason.decode!()
  defp get(m, k, default \\ nil), do: Map.get(m, k, Map.get(m, Atom.to_string(k), default))
  defp val(m, k), do: Map.get(m, k, Map.get(m, String.to_atom(k)))

  defp path_has_symlink?(path) do
    path |> Path.split() |> Enum.scan(fn part, acc -> Path.join(acc, part) end) |> Enum.any?(&symlink?/1)
  end
  defp symlink?(path), do: match?({:ok, %{type: :symlink}}, File.lstat(path))
  defp symlink_component?(root, parts), do: parts |> Enum.scan(root, &Path.join(&2, &1)) |> Enum.any?(&symlink?/1)
  defp safe_relative?(path) when is_binary(path), do: Path.type(path) == :relative and
    not Enum.member?(Path.split(path), "..")
  defp safe_relative?(_), do: false
  defp inside?(path, root) do
    rel = Path.relative_to(Path.expand(path), root)
    rel != ".." and not String.starts_with?(rel, "../")
  end

  defp ensure_journal(root) do
    beam = Path.join(root, ".beam-lisp")
    journal = Path.join(root, @journal)
    cond do
      symlink?(beam) or symlink?(journal) -> {:error, :symlink_journal}
      true -> File.mkdir_p(journal)
    end
  end
  defp journal_file(root, id), do: journal_path(root, hash(id) <> ".json")
  defp evidence_file(root, id), do: journal_path(root, hash(id) <> ".verify.json")
  defp journal_path(root, name) do
    path = Path.join([root, @journal, name])
    if symlink_component?(root, Path.split(Path.relative_to(path, root))), do: {:error, :symlink_journal}, else: {:ok, path}
  end
  defp safe_read_journal(root, file) do
    if symlink_component?(root, Path.split(Path.relative_to(file, root))), do: {:error, :symlink_journal}, else: File.read(file)
  end

  defp journal(p, evidence, phase) do
    with {:ok, file} <- journal_file(p.workspace, p.id) do
      data = %{phase: phase, recovery: if(phase == :applied, do: :new, else: :pending), id: p.id,
        target: p.target, selector: p.selector, old_hash: p.old_hash, after_hash: p.new_hash,
        old_form: binary_part(p.old_bytes, p.span.start, p.span.stop - p.span.start),
        verification_evidence: evidence, command_descriptor: val(evidence, "command_descriptor"), status: phase}
      case atomic(file, Jason.encode!(data)) do
        :ok -> {:ok, data}
        error -> error
      end
    end
  end

  defp recover(value, root) do
    if val(value, "phase") in [:intent, "intent"] do
      with {:ok, path} <- target(root, val(value, "target")), {:ok, bytes} <- File.read(path) do
        recovery = cond do
          hash(bytes) == val(value, "old_hash") -> "old"
          hash(bytes) == val(value, "after_hash") -> "new"
          true -> "neither"
        end
        {:ok, Map.put(value, "recovery", recovery)}
      end
    else
      {:ok, Map.put(value, "recovery", "new")}
    end
  end

  defp atomic(path, bytes) do
    tmp = path <> ".tmp-" <> Integer.to_string(:erlang.unique_integer([:positive]))
    mode = case File.stat(path) do {:ok, stat} -> stat.mode; _ -> nil end
    result =
      with :ok <- File.write(tmp, bytes, [:binary]),
           :ok <- maybe_chmod(tmp, mode),
           {:ok, fd} <- :file.open(String.to_charlist(tmp), [:read, :write, :binary]),
           :ok <- :file.sync(fd),
           :ok <- :file.close(fd),
           :ok <- File.rename(tmp, path),
           :ok <- sync_parent(path) do
        :ok
      end
    if result != :ok, do: File.rm(tmp)
    result
  end
  defp maybe_chmod(_, nil), do: :ok
  defp maybe_chmod(path, mode), do: File.chmod(path, mode)
  defp sync_parent(path) do
    case :file.open(String.to_charlist(Path.dirname(path)), [:read, :raw, :directory]) do
      {:ok, fd} -> result = :file.sync(fd); :file.close(fd); result
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock(root, fun) do
    path = Path.join(root, @lock)
    with :ok <- ensure_lock_parent(root) do
      case File.mkdir(path) do
        :ok -> try do fun.() after File.rmdir(path) end
        {:error, :eexist} -> {:error, :busy}
        {:error, reason} -> {:error, {:lock_failed, reason}}
      end
    end
  end
  defp ensure_lock_parent(root) do
    parent = Path.dirname(Path.join(root, @lock))
    if symlink?(parent), do: {:error, :symlink_journal}, else: File.mkdir_p(parent)
  end

  defp diff(old, new, target), do: "--- #{target}\n+++ #{target}\n" <>
    if(old == new, do: "", else: "@@ changed #{hash(new)} @@\n")
end
