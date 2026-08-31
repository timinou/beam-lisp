defmodule BeamLisp.ExecutorSSHBlTest do
  @moduledoc """
  End-to-end for the MAXIMALIST bl SSH executor (priv/executor/ssh.bl): the whole
  daemon is beam-lisp; the only Elixir is the generic BeamLisp.SSHKeyCB shim.

  A real `ssh` client (openssh) authenticates by a store-enrolled public key and
  drives the capped `bl>` REPL. We assert: granted cap runs, ungranted cap is
  denied at compile time, and a non-enrolled key is refused at auth.

  Uses the openssh CLI (not OTP's ssh client) because it reliably offers an
  explicit `-i` identity with IdentitiesOnly; input is piped without a PTY so
  IO.gets sees clean newline-framed lines.
  """
  use ExUnit.Case, async: false
  @moduletag timeout: 90_000

  setup_all do
    {:ok, _} = Application.ensure_all_started(:beam_lisp)
    {:ok, _} = Application.ensure_all_started(:ssh)
    BeamLisp.init()
    BeamLisp.Env.add_search_path("priv")
    :ok = BeamLisp.Loader.ensure_loaded("executor.ssh")
    :ok
  end

  defp client_key do
    dir = Path.join(System.tmp_dir!(), "blssh_c_#{:erlang.unique_integer([:positive])}")
    File.rm_rf!(dir); File.mkdir_p!(dir)
    {_, 0} = System.cmd("ssh-keygen", ["-t", "ed25519", "-f", "#{dir}/id", "-N", "", "-q"])
    {dir, File.read!("#{dir}/id.pub") |> String.trim()}
  end

  defp host_dir do
    dir = Path.join(System.tmp_dir!(), "blssh_h_#{:erlang.unique_integer([:positive])}")
    File.rm_rf!(dir); File.mkdir_p!(dir)
    {_, 0} = System.cmd("ssh-keygen", ["-t", "rsa", "-b", "2048",
                                        "-f", "#{dir}/ssh_host_rsa_key", "-N", "", "-q"])
    dir
  end

  # Enroll `enrolled_line` for alice; start the bl daemon; return its port.
  defp start(enrolled_line, host) do
    setup =
      BeamLisp.eval("""
      (ns test.blssh.setup (:require [executor.ssh :as ex] [executor.store :as st] [auth]))
      (let [root (auth/keypair) conn (st/open)]
        (st/enroll! conn "alice" "#{enrolled_line}"
          (auth/encode-base64 (auth/issue root [["user" "alice"] ["right" "Elixir.String" "call"]])))
        {:port (ex/port (elem (ex/serve {:port 0 :system-dir "#{host}" :store conn
                                         :root-pub (auth/public root)
                                         :policy {:mem-per-session 2000000 :mem-per-user 8000000
                                                  :disk-per-session 0 :disk-per-user 0}}) 1))})
      """)

    Map.get(setup, :port)
  end

  defp ssh_pipe(port, key_dir, input) do
    cmd =
      "printf '#{input}' | ssh -p #{port} -i #{key_dir}/id -o IdentitiesOnly=yes " <>
        "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null " <>
        "-o PasswordAuthentication=no -o BatchMode=yes alice@127.0.0.1 2>&1"

    {out, _} = System.cmd("bash", ["-c", cmd], stderr_to_stdout: true)
    out
  end

  test "enrolled key: granted cap runs, ungranted denied at compile time" do
    {cdir, line} = client_key()
    port = start(line, host_dir())

    out = ssh_pipe(port, cdir, ~S[(String/upcase \"hi\")\n(File/read \"/etc/passwd\")\n:quit\n])

    assert String.contains?(out, "=> HI"), "granted String/upcase must run:\n#{out}"
    assert String.contains?(out, "not granted"),
           "ungranted File must be denied at compile time:\n#{out}"
  end

  test "non-enrolled key is refused at authentication" do
    {_cdir, alice_line} = client_key()
    {eve_dir, _} = client_key()          # eve's key is NOT enrolled
    port = start(alice_line, host_dir())

    out = ssh_pipe(port, eve_dir, ~S[(String/upcase \"hi\")\n:quit\n])

    refute String.contains?(out, "=> HI"), "unenrolled key must not reach the REPL:\n#{out}"
    assert String.contains?(out, "Permission denied") or String.contains?(out, "publickey"),
           "auth should be refused:\n#{out}"
  end

  test "revoked principal can no longer authenticate" do
    {cdir, line} = client_key()
    host = host_dir()

    # start with alice enrolled, then revoke through the same store
    setup =
      BeamLisp.eval("""
      (ns test.blssh.revoke (:require [executor.ssh :as ex] [executor.store :as st] [auth]))
      (let [root (auth/keypair) conn (st/open)]
        (st/enroll! conn "alice" "#{line}"
          (auth/encode-base64 (auth/issue root [["user" "alice"] ["right" "Elixir.String" "call"]])))
        (st/revoke! conn "alice")
        {:port (ex/port (elem (ex/serve {:port 0 :system-dir "#{host}" :store conn
                                         :root-pub (auth/public root)
                                         :policy {:mem-per-session 2000000 :mem-per-user 8000000
                                                  :disk-per-session 0 :disk-per-user 0}}) 1))})
      """)

    out = ssh_pipe(Map.get(setup, :port), cdir, ~S[(String/upcase \"hi\")\n:quit\n])
    refute String.contains?(out, "=> HI"), "revoked principal must not reach the REPL:\n#{out}"
  end
end
