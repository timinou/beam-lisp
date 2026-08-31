defmodule BeamLisp.CrossNodeConveyanceSpikeTest do
  @moduledoc """
  SPIKE — cross-node capability conveyance.

  Can a capability ceiling cross a Distributed-Erlang node boundary, so a
  remote spawn on node B runs under the caller's caps — not B's :global?

  Finding, in three tests:
   1. Naive env-token conveyance FAILS CLOSED across nodes (correct): an
      env-ref is node-local; env/bind re-derives caps from B's OWN registry,
      so a smuggled token grants ZERO caps on B.
   2. The right vehicle is the BISCUIT token: ship it, authorize+fork on B.
      Authority arrives as signed data, re-materializes as a local capped env.
   3. Deny crosses too: a forged token forks nothing on B.
  """
  use ExUnit.Case, async: false

  @moduletag :spike
  @moduletag timeout: 120_000

  setup_all do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:"spike_primary@127.0.0.1", :longnames])
    end

    {:ok, _} = Application.ensure_all_started(:beam_lisp)
    BeamLisp.init()
    BeamLisp.Env.add_search_path("priv")
    :ok = BeamLisp.Loader.ensure_loaded("auth")
    :ok = BeamLisp.Loader.ensure_loaded("env")
    :ok
  end

  defp start_executor_node! do
    {:ok, peer, node} =
      :peer.start_link(%{
        name: :spike_exec,
        host: ~c"127.0.0.1",
        args: [~c"-setcookie", Atom.to_charlist(:erlang.get_cookie())]
      })

    :ok = :erpc.call(node, :code, :add_pathsz, [:code.get_path()])
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:beam_lisp])
    :ok = :erpc.call(node, BeamLisp, :init, [])
    :ok = :erpc.call(node, BeamLisp.Env, :add_search_path, ["priv"])
    :ok = :erpc.call(node, BeamLisp.Loader, :ensure_loaded, ["auth"])
    :ok = :erpc.call(node, BeamLisp.Loader, :ensure_loaded, ["env"])
    {peer, node}
  end

  defp eval_on(node, src), do: :erpc.call(node, BeamLisp, :eval, [src])

  defp k(map, atom) do
    hyphen = atom |> Atom.to_string() |> String.replace("_", "-") |> String.to_atom()
    cond do
      Map.has_key?(map, hyphen) -> Map.get(map, hyphen)
      Map.has_key?(map, atom) -> Map.get(map, atom)
      is_map(map) -> Map.get(map, Atom.to_string(hyphen))
    end
  end

  test "naive env-token conveyance fails CLOSED across nodes (correct, not a bug)" do
    {peer, node} = start_executor_node!()

    try do
      token =
        BeamLisp.Env.with_env(BeamLisp.Env.fork(:global, caps: [String]), fn ->
          BeamLisp.Env.capture()
        end)

      assert %{env: {:env, ref}, caps: caps} = token
      assert is_reference(ref)
      assert MapSet.member?(caps, String)

      derived = :erpc.call(node, BeamLisp.Env, :caps_of, [token.env])
      assert derived == MapSet.new(),
             "an env-ref from another node must derive ZERO caps on B (fail closed)"
    after
      :peer.stop(peer)
    end
  end

  test "Biscuit token conveys the ceiling: authorize+fork on B, granted runs / ungranted denied" do
    {peer, node} = start_executor_node!()

    try do
      issued =
        BeamLisp.eval("""
        (ns spike.issuer (:require [auth]))
        (let [root (auth/keypair)
              token (auth/issue root [["user" "worker-7"]
                                      ["right" "Elixir.String" "call"]])]
          {:root-pub (Base/url_encode64 (auth/public root))
           :token    (auth/encode-base64 token)})
        """)

      root_pub_b64 = k(issued, :root_pub)
      token_b64 = k(issued, :token)
      assert is_binary(root_pub_b64)
      assert is_binary(token_b64)

      src =
        """
        (ns spike.exec (:require [auth] [env]))
        (let [root-pub (Base/url_decode64! "#{root_pub_b64}")
              token    (auth/decode-base64 "#{token_b64}")
              ctx      (auth/context {:policies [(auth/allow [])]})
              forked   (auth/sandbox-fork root-pub token ctx :global)]
          (if (contains? forked :ok)
            (env/with-env (:ok forked)
              (fn []
                {:granted (env/eval "(ns b.ok) (String/upcase \\"hi from B\\")")
                 :denied  (try (env/eval "(ns b.no) (File/read \\"/etc/passwd\\")")
                               (catch _ :denied-at-COMPILE-time))
                 :caps    (env/allowed? "Elixir.String")
                 :file?   (env/allowed? "Elixir.File")}))
            {:error (:reason (:error forked))}))
        """

      result = eval_on(node, src)

      assert k(result, :granted) == "HI FROM B"
      assert k(result, :denied) == :"denied-at-COMPILE-time"
      assert k(result, :caps) == true
      assert k(result, :file?) == false
    after
      :peer.stop(peer)
    end
  end

  test "a forged token forks NOTHING on B (deny crosses the wire too)" do
    {peer, node} = start_executor_node!()

    try do
      issued =
        BeamLisp.eval("""
        (ns spike.issuer2 (:require [auth]))
        (let [real   (auth/keypair)
              forger (auth/keypair)
              token  (auth/issue forger [["right" "Elixir.File" "write"]])]
          {:root-pub (Base/url_encode64 (auth/public real))
           :token    (auth/encode-base64 token)})
        """)

      root_pub_b64 = k(issued, :root_pub)
      token_b64 = k(issued, :token)

      src =
        """
        (ns spike.exec (:require [auth] [env]))
        (let [root-pub (Base/url_decode64! "#{root_pub_b64}")
              token    (auth/decode-base64 "#{token_b64}")
              ctx      (auth/context {:policies [(auth/allow [])]})
              forked   (auth/sandbox-fork root-pub token ctx :global)]
          {:forked? (contains? forked :ok)
           :verdict (if (contains? forked :error) (:verdict (:error forked)) :allow)})
        """

      result = eval_on(node, src)
      assert k(result, :forked?) == false, "a forged token must fork NO env on B"
      assert k(result, :verdict) == :deny
    after
      :peer.stop(peer)
    end
  end
end
