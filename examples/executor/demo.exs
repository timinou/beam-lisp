# examples/executor/demo.exs — a live capped-shell SSH executor you can ssh into.
#
#   Run:   mix run --no-halt examples/executor/demo.exs
#   Then:  (copy the printed `ssh …` command and run it in another terminal)
#
# It sets up a throwaway SSH keypair, enrolls two demo users in the datom
# `executor.store`, mints them Biscuit exec-tokens with DIFFERENT capabilities,
# and starts the pure-beam-lisp SSH executor (priv/executor/ssh.bl). You then
# ssh in and get a capped `bl>` REPL — caps enforced at compile time, memory and
# disk bounded per the policy.
#
#   alice → String only   : (String/upcase "hi") works; (File/read …) is denied.
#   bob   → String + Enum  : can also (Enum/map …); still no File / System.
#
# Nothing here touches your real ~/.ssh — everything lives under /tmp/bl-exec-demo.

{:ok, _} = Application.ensure_all_started(:beam_lisp)
{:ok, _} = Application.ensure_all_started(:ssh)
BeamLisp.init()
BeamLisp.Env.add_search_path("priv")
:ok = BeamLisp.Loader.ensure_loaded("executor.ssh")

demo = "/tmp/bl-exec-demo"
File.rm_rf!(demo)
File.mkdir_p!(demo)

# Host key for the daemon.
host = Path.join(demo, "host")
File.mkdir_p!(host)
System.cmd("ssh-keygen", ["-t", "rsa", "-b", "2048", "-f", "#{host}/ssh_host_rsa_key", "-N", "", "-q"])

# A client keypair per user (throwaway).
gen = fn user ->
  dir = Path.join(demo, user)
  File.mkdir_p!(dir)
  System.cmd("ssh-keygen", ["-t", "ed25519", "-f", "#{dir}/id", "-N", "", "-q", "-C", "#{user}@demo"])
  {dir, File.read!("#{dir}/id.pub") |> String.trim()}
end

{alice_dir, alice_line} = gen.("alice")
{bob_dir, bob_line} = gen.("bob")

# Build the store + tokens + daemon, all in beam-lisp. alice gets String only,
# bob gets String + Enum. Policy: small memory ceiling, no disk.
setup =
  BeamLisp.eval("""
  (ns demo.exec (:require [executor.ssh :as ex] [executor.store :as st] [auth]))
  (let [root (auth/keypair)
        conn (st/open)
        alice-tok (auth/issue root [["user" "alice"] ["right" "Elixir.String" "call"]])
        bob-tok   (auth/issue root [["user" "bob"]
                                    ["right" "Elixir.String" "call"]
                                    ["right" "Elixir.Enum" "call"]])]
    (st/enroll! conn "alice" "#{alice_line}" (auth/encode-base64 alice-tok))
    (st/enroll! conn "bob"   "#{bob_line}"   (auth/encode-base64 bob-tok))
    (let [d (ex/serve {:port 0 :system-dir "#{host}" :store conn
                       :root-pub (auth/public root)
                       :policy {:mem-per-session 5000000 :mem-per-user 20000000
                                :disk-per-session 0 :disk-per-user 0}})]
      {:port (ex/port (elem d 1))}))
  """)

port = Map.get(setup, :port)

ssh = fn user, dir ->
  "ssh -p #{port} -i #{dir}/id -o IdentitiesOnly=yes " <>
    "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null " <>
    "-o PasswordAuthentication=no #{user}@127.0.0.1"
end

IO.puts("""

┌──────────────────────────────────────────────────────────────────────────┐
│  capped beam-lisp SSH executor is LIVE on port #{port}
└──────────────────────────────────────────────────────────────────────────┘

Open another terminal and ssh in. Two users, different capabilities:

  alice — String only:
    #{ssh.("alice", alice_dir)}

  bob — String + Enum:
    #{ssh.("bob", bob_dir)}

At the bl> prompt, try:
    (String/upcase "hello")                 ; alice OK   bob OK
    (Enum/count [1 2 3])                     ; alice DENIED   bob OK
    (File/read "/etc/passwd")               ; both DENIED (compile-time)
    (count (range 1 100))                    ; both OK (core fns)
    :quit                                    ; leave

Everything the token did not grant is UNSPEAKABLE — a compile error, not a
runtime check. Memory is bounded per session; a runaway allocation kills only
that eval, never the daemon.

Press Ctrl-C twice to stop the daemon.
""")

# Keep the VM alive so the daemon serves. (mix run --no-halt also keeps it up.)
Process.sleep(:infinity)
