defmodule BeamLisp.DevChangeTest do
  use ExUnit.Case, async: false

  alias BeamLisp.DevChange

  defp fixture!(source) do
    root = Path.join(System.tmp_dir!(), "beam_lisp_dev_change_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "fixture.bl"), source)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp spec(root, extra \\ %{}) do
    path = Path.join(root, "fixture.bl")
    Map.merge(%{
      workspace: root,
      target: "fixture.bl",
      selector: "demo/target",
      replacement: "(defn target [] \"changed\")",
      expected_hash: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower),
      id: "edit-#{System.unique_integer([:positive])}",
      verification: %{argv: ["true"]}
    }, extra)
  end

  test "real verifier reports the child exit status, not its launcher status" do
    root = fixture!("(ns demo)\n(defn target [] :old)\n")
    assert {:ok, passing} = DevChange.plan(spec(root, %{verification: %{argv: ["true"], timeout: 5_000}}))
    assert {:ok, evidence} = DevChange.verify(passing)
    assert evidence.exit_status == 0
    assert evidence.status == :verified

    assert {:ok, failing} = DevChange.plan(spec(root, %{verification: %{argv: ["false"], timeout: 5_000}}))
    assert {:error, {:verification_failed, failure}} = DevChange.verify(failing)
    assert failure.exit_status != 0
    assert File.read!(Path.join(root, "fixture.bl")) == passing.old_bytes
  end

  test "verification evaluates the candidate while the source workspace stays unchanged" do
    BeamLisp.init()
    ns = "candidate_behavior_#{System.unique_integer([:positive])}"
    original = "(ns #{ns})\n(defn target [] \"old\")\n"
    root = fixture!(original)
    assert {:ok, plan} = DevChange.plan(spec(root, %{selector: ns <> "/target"}))
    runner = fn command ->
      refute command.cwd == root
      child = BeamLisp.Env.fork()
      try do
        value = BeamLisp.Env.with_env(child, fn ->
          BeamLisp.eval(File.read!(Path.join(command.cwd, "fixture.bl")) <> "\n(#{ns}/target)")
        end)
        assert value == "changed"
        :ok
      after
        BeamLisp.Env.destroy(child)
      end
    end
    assert {:ok, %{status: :verified}} = DevChange.verify(plan, runner: runner)
    assert File.read!(Path.join(root, "fixture.bl")) == original
  end

  test "plan and preview do not modify source bytes" do
    source = """
    (ns demo)
    ; preserve this comment (and delimiter-looking text: ) )
    (defn sibling [] "keep λ")
    (defn target [] "old")
    """
    root = fixture!(source)
    path = Path.join(root, "fixture.bl")
    before = File.read!(path)

    assert {:ok, plan} = DevChange.plan(spec(root))
    assert {:ok, preview} = DevChange.preview(plan)
    assert preview.id == plan.id
    assert preview.old_hash == plan.old_hash
    assert preview.new_hash == plan.new_hash
    assert preview.diff =~ "@@ changed"
    assert File.read!(path) == before
  end

  test "candidate changes only selected top-level form and preserves exact surrounding bytes" do
    source = """
    (ns demo)\r\n; λ comment\r\n(defn sibling [] "text ) (def fake [] )")\r\n(defn target [] "old value")\r\n(defn tail [] :tail)\r\n
    """
    root = fixture!(source)
    path = Path.join(root, "fixture.bl")

    assert {:ok, plan} = DevChange.plan(spec(root))
    prefix = binary_part(source, 0, plan.span.start)
    suffix = binary_part(source, plan.span.stop, byte_size(source) - plan.span.stop)
    candidate_suffix = binary_part(plan.candidate_bytes, plan.span.start + byte_size(plan.replacement), byte_size(plan.candidate_bytes) - plan.span.start - byte_size(plan.replacement))
    assert binary_part(plan.candidate_bytes, 0, plan.span.start) == prefix
    assert candidate_suffix == suffix
    assert plan.candidate_bytes =~ "sibling [] \"text ) (def fake [] )\""
    assert plan.candidate_bytes =~ "tail [] :tail"
    assert plan.candidate_bytes =~ "target [] \"changed\""
    assert File.read!(path) == source
  end

  test "rejects missing, malformed, and ambiguous definitions" do
    missing_ns = fixture!("(defn target [] :ok)\n")
    assert DevChange.plan(spec(missing_ns)) == {:error, :missing_namespace}

    malformed = fixture!("(ns demo)\n(defn target [] (if true :yes)\n")
    assert DevChange.plan(spec(malformed)) == {:error, :invalid_source}

    ambiguous = fixture!("(ns demo)\n(defn target [] :one)\n(defn target [] :two)\n")
    assert DevChange.plan(spec(ambiguous)) == {:error, :ambiguous_target}
  end

  test "rejects traversal, absolute, symlink, missing, and unsupported targets" do
    root = fixture!("(ns demo)\n(defn target [] :ok)\n")
    outside = Path.join(root, "outside.txt")
    File.write!(outside, "not source")
    File.ln_s!(outside, Path.join(root, "link.bl"))

    assert DevChange.plan(spec(root, %{target: "../outside.txt"})) == {:error, :invalid_target}
    assert DevChange.plan(spec(root, %{target: Path.join(root, "fixture.bl")})) == {:error, :invalid_target}
    assert DevChange.plan(spec(root, %{target: "link.bl"})) == {:error, :symlink_target}
    assert DevChange.plan(spec(root, %{target: "missing.bl"})) == {:error, :missing_target}
    assert DevChange.plan(spec(root, %{target: "outside.txt"})) == {:error, :unsupported_target}
  end

  test "rejects stale basis and invalid replacements" do
    root = fixture!("(ns demo)\n(defn target [] :ok)\n")
    assert DevChange.plan(spec(root, %{expected_hash: String.duplicate("0", 64)})) == {:error, :stale_basis}
    assert DevChange.plan(spec(root, %{replacement: "not a form"})) == {:error, :invalid_replacement}
    assert DevChange.plan(spec(root, %{replacement: "(defn target []"})) == {:error, :invalid_replacement}
  end

  test "verification uses injected runner and reports success or failure" do
    root = fixture!("(ns demo)\n(defn target [] :ok)\n")
    assert {:ok, plan} = DevChange.plan(spec(root))

    test_pid = self()
    assert {:ok, verified} = DevChange.verify(plan, runner: fn command -> send(test_pid, {:ran, command}); :ok end)
    assert_receive {:ran, %{argv: ["true"], cwd: cwd}}
    assert String.starts_with?(cwd, System.tmp_dir!())
    assert verified.status == :verified
    assert verified.edit_id == plan.id
    assert verified.basis_hash == plan.old_hash
    assert verified.candidate_hash == plan.new_hash

    assert {:error, {:verification_failed, evidence}} =
             DevChange.verify(plan, runner: fn _ -> {:error, :bad_fixture} end)
    assert evidence.status == :failed
    assert evidence.exit_status == 1
    assert evidence.output =~ "bad_fixture"
  end

  test "verification refuses absent and non-allowlisted commands" do
    root = fixture!("(ns demo)\n(defn target [] :ok)\n")
    assert {:ok, plan} = DevChange.plan(spec(root, %{verification: nil}))
    assert DevChange.verify(plan, runner: fn _ -> flunk("runner must not run") end) == {:error, :missing_verification_command}

    assert {:ok, forbidden} = DevChange.plan(spec(root, %{verification: %{argv: ["./build"]}}))
    assert DevChange.verify(forbidden, runner: fn _ -> flunk("runner must not run") end) == {:error, :command_not_allowlisted}
  end

  test "apply requires authorization and verified candidate" do
    root = fixture!("(ns demo)\n(defn target [] :ok)\n")
    assert {:ok, plan} = DevChange.plan(spec(root))
    bad_auth = %{id: plan.id, candidate_hash: String.duplicate("0", 64)}
    assert DevChange.apply!(plan, %{candidate_hash: plan.new_hash, status: :ok}, bad_auth) == {:error, :unauthorized}
    forged = %{edit_id: plan.id, basis_hash: plan.old_hash, candidate_hash: plan.new_hash, status: :verified}
    assert DevChange.apply!(plan, forged, %{id: plan.id, candidate_hash: plan.new_hash}) == {:error, :enoent}
    assert File.read!(Path.join(root, "fixture.bl")) =~ "[] :ok"
  end

  test "apply is repeat-safe, receipt is durable, drift blocks undo, and undo proposes inverse" do
    root = fixture!("(ns demo)\n(defn target [] :ok)\n")
    assert {:ok, plan} = DevChange.plan(spec(root))
    assert {:ok, receipt} = DevChange.verify(plan, runner: fn _ -> :ok end)
    auth = %{id: plan.id, candidate_hash: plan.new_hash}

    assert {:ok, first} = DevChange.apply!(plan, receipt, auth)
    assert first.phase == :applied
    assert {:ok, second} = DevChange.apply!(plan, receipt, auth)
    assert second["phase"] == "applied"
    assert {:ok, stored} = DevChange.receipt(plan.id, root)
    assert stored["after_hash"] == plan.new_hash

    assert {:ok, inverse} = DevChange.undo!(plan.id, auth, root)
    assert inverse.replacement == "(defn target [] :ok)"
    File.write!(Path.join(root, "fixture.bl"), inverse.candidate_bytes <> "\n")
    assert DevChange.undo!(plan.id, auth, root) == {:error, :conflict}
  end

  test "invalid plans and receipt queries return tagged errors" do
    assert DevChange.plan(:not_a_map) == {:error, :invalid_spec}
    assert DevChange.preview(%{}) == {:error, :invalid_plan}
    assert DevChange.verify(%{}, []) == {:error, :invalid_plan}
    assert DevChange.receipt("missing", System.tmp_dir!()) == {:error, :not_found}
    assert DevChange.receipt(:bad, System.tmp_dir!()) == {:error, :invalid_receipt_query}
  end
end


defmodule BeamLisp.DevChangeHardeningTest do
  use ExUnit.Case, async: false
  alias BeamLisp.DevChange

  defp fixture!(source) do
    root = Path.join(System.tmp_dir!(), "beam_lisp_dev_change_hardening_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "fixture.bl"), source)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp spec(root, extra \\ %{}) do
    path = Path.join(root, "fixture.bl")
    Map.merge(%{workspace: root, target: "fixture.bl", selector: "demo/target",
      replacement: "(defn target [] \"changed\")",
      expected_hash: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower),
      id: "edit-#{System.unique_integer([:positive])}", verification: %{argv: ["true"]}}, extra)
  end

test "strict scanner rejects malformed delimiters, quoted/discarded targets, renames, and multiple forms" do
  for source <- [
        "(ns demo)\n(defn target [] [1 2})\n",
        "(ns demo)\n(defn target [] {1 2])\n",
        "(ns demo)\n'(defn target [] :quoted)\n",
        "(ns demo)\n#_(defn target [] :discarded)\n"
      ] do
    root = fixture!(source)
    assert DevChange.plan(spec(root)) in [{:error, :invalid_source}, {:error, :target_not_found}]
  end

  root = fixture!("(ns demo)\n(defn target [] :ok)\n")
  assert DevChange.plan(spec(root, %{replacement: "(defn renamed [] :bad)"})) == {:error, :invalid_replacement}
  assert DevChange.plan(spec(root, %{replacement: "(defn target [] :a) (defn target [] :b)"})) == {:error, :invalid_replacement}
end

test "verify revalidates immutable plan fields and source basis" do
  root = fixture!("(ns demo)\n(defn target [] :ok)\n")
  assert {:ok, plan} = DevChange.plan(spec(root))
  runner = fn _ -> flunk("invalid plans must not execute") end

  assert DevChange.verify(%{plan | candidate_bytes: plan.candidate_bytes <> "x"}, runner: runner) == {:error, :invalid_plan}
  assert DevChange.verify(%{plan | selector: "demo/other"}, runner: runner) == {:error, :invalid_plan}

  File.write!(Path.join(root, "fixture.bl"), "(ns demo)\n(defn target [] :drift)\n")
  assert DevChange.verify(plan, runner: runner) == {:error, :conflict}
end

test "caller allowlist is ignored and runner failures are contained and cleaned" do
  root = fixture!("(ns demo)\n(defn target [] :ok)\n")
  assert {:ok, plan} = DevChange.plan(spec(root, %{verification: %{argv: ["forbidden"], allow: ["forbidden"]}}))
  assert DevChange.verify(plan, runner: fn _ -> flunk("must not run") end) == {:error, :command_not_allowlisted}

  assert {:ok, allowed} = DevChange.plan(spec(root))
  parent = self()
  assert {:error, {:runner_failed, _}} = DevChange.verify(allowed, runner: fn command ->
    send(parent, {:failed_copy, Path.dirname(command.cwd)})
    exit(:runner_crash)
  end)
  assert_receive {:failed_copy, failed_copy}
  refute File.exists?(failed_copy)
  assert File.read!(Path.join(root, "fixture.bl")) =~ "[] :ok"
end

test "default runner times out a supervised OS process without changing source" do
  root = fixture!("(ns demo)\n(defn target [] :ok)\n")
  verification = %{argv: ["elixir", "-e", "spawn(fn -> Process.sleep(:infinity) end); Process.sleep(:infinity)"], timeout: 25}
  assert {:ok, plan} = DevChange.plan(spec(root, %{verification: verification}))
  assert DevChange.verify(plan) == {:error, :verification_timeout}
  assert File.read!(Path.join(root, "fixture.bl")) =~ "[] :ok"
end

test "verification honors descriptor cwd and refuses workspace symlinks" do
  root = fixture!("(ns demo)\n(defn target [] :ok)\n")
  File.mkdir_p!(Path.join(root, "nested"))
  File.write!(Path.join(root, "real"), "outside copy")
  assert {:ok, plan} = DevChange.plan(spec(root, %{verification: %{argv: ["true"], cwd: "nested"}}))
  parent = self()
  assert {:ok, _} = DevChange.verify(plan, runner: fn command -> send(parent, {:cwd, command.cwd}); :ok end)
  assert_receive {:cwd, cwd}
  assert Path.basename(cwd) == "nested"

  File.ln_s!(Path.join(root, "real"), Path.join(root, "copied-link"))
  assert DevChange.verify(plan, runner: fn _ -> flunk("copy must refuse first") end) == {:error, :symlink_in_workspace}
end

test "apply trusts persisted evidence, rejects plan mutation, and preserves source mode" do
  root = fixture!("(ns demo)\n(defn target [] :ok)\n")
  path = Path.join(root, "fixture.bl")
  File.chmod!(path, 0o640)
  assert {:ok, plan} = DevChange.plan(spec(root))
  assert {:ok, evidence} = DevChange.verify(plan, runner: fn _ -> :ok end)
  auth = %{id: plan.id, candidate_hash: plan.new_hash}

  forged = %{evidence | candidate_hash: String.duplicate("0", 64)}
  assert {:ok, _} = DevChange.apply!(plan, forged, auth)
  assert {:ok, stat} = File.stat(path)
  assert Bitwise.band(stat.mode, 0o777) == 0o640

  root2 = fixture!("(ns demo)\n(defn target [] :ok)\n")
  assert {:ok, plan2} = DevChange.plan(spec(root2))
  assert {:ok, _} = DevChange.verify(plan2, runner: fn _ -> :ok end)
  tampered = %{plan2 | old_hash: String.duplicate("f", 64)}
  assert DevChange.apply!(tampered, %{}, %{id: plan2.id, candidate_hash: plan2.new_hash}) == {:error, :invalid_plan}
end

test "busy lock and reused edit IDs refuse without overwrite" do
  root = fixture!("(ns demo)\n(defn target [] :ok)\n")
  assert {:ok, first} = DevChange.plan(spec(root, %{id: "stable"}))
  assert {:ok, evidence} = DevChange.verify(first, runner: fn _ -> :ok end)
  File.mkdir_p!(Path.join(root, ".beam-lisp/change.lock"))
  assert DevChange.apply!(first, evidence, %{id: first.id, candidate_hash: first.new_hash}) == {:error, :busy}
  File.rmdir!(Path.join(root, ".beam-lisp/change.lock"))
  assert {:ok, _} = DevChange.apply!(first, evidence, %{id: first.id, candidate_hash: first.new_hash})

  File.write!(Path.join(root, "fixture.bl"), first.old_bytes)
  assert {:ok, different} = DevChange.plan(spec(root, %{id: "stable", replacement: "(defn target [] :different)"}))
  assert {:ok, different_evidence} = DevChange.verify(different, runner: fn _ -> :ok end)
  assert DevChange.apply!(different, different_evidence, %{id: different.id, candidate_hash: different.new_hash}) == {:error, :edit_id_reused}
end

test "intent recovery reports old, new, and neither explicitly" do
  root = fixture!("(ns demo)\n(defn target [] :ok)\n")
  assert {:ok, plan} = DevChange.plan(spec(root, %{id: "recover"}))
  dir = Path.join(root, ".beam-lisp/change-journal")
  File.mkdir_p!(dir)
  name = :crypto.hash(:sha256, plan.id) |> Base.encode16(case: :lower)
  journal = Path.join(dir, name <> ".json")
  body = %{phase: :intent, id: plan.id, target: plan.target, selector: plan.selector,
    old_hash: plan.old_hash, after_hash: plan.new_hash} |> JSON.encode!()
  File.write!(journal, body)

  assert {:ok, %{"recovery" => "old"}} = DevChange.receipt(plan.id, root)
  File.write!(Path.join(root, "fixture.bl"), plan.candidate_bytes)
  assert {:ok, %{"recovery" => "new"}} = DevChange.receipt(plan.id, root)
  File.write!(Path.join(root, "fixture.bl"), "(ns demo)\n(defn target [] :other)\n")
  assert {:ok, %{"recovery" => "neither"}} = DevChange.receipt(plan.id, root)
end

test "workspace ancestors and journal symlinks are refused" do
  base = fixture!("(ns demo)\n(defn target [] :ok)\n")
  linked = base <> "-linked"
  File.ln_s!(base, linked)
  on_exit(fn -> File.rm(linked) end)
  assert DevChange.plan(spec(linked)) == {:error, :symlink_workspace}

  root = fixture!("(ns demo)\n(defn target [] :ok)\n")
  outside = fixture!("(ns outside)\n(defn target [] :outside)\n")
  File.mkdir_p!(Path.join(root, ".beam-lisp"))
  File.ln_s!(outside, Path.join(root, ".beam-lisp/change-journal"))
  assert {:ok, plan} = DevChange.plan(spec(root))
  assert DevChange.verify(plan, runner: fn _ -> :ok end) == {:error, :symlink_in_workspace}
end

end

