defmodule BeamLisp.ContractEmitTest do
  use ExUnit.Case, async: false

  # The BEAM half of `defcontract`, gated from Elixir so it runs in `mix test`
  # (CI) rather than only under `mix beam_lisp.test`.
  #
  # test/bl/contract_test.bl covers the emitter's behaviour in beam-lisp itself,
  # where the assertions read in the language the contract is written in. This
  # file exists for one reason the .bl suite cannot serve: it puts the
  # acceptance number in the DEFAULT test path, so a regression fails the build
  # everyone already runs.
  #
  # ── the acceptance number ──────────────────────────────────────────────────
  #
  # `SpacetimeLvWeb.CounterLive` (verse: elixir/spacetime_lv) declares its
  # events/assigns/pushes through the Elixir DSL, which hashes the contract JSON
  # to the constant below. A beam-lisp term must reproduce those exact bytes.
  #
  # Byte equality, not "equivalent": verse's src/analysis/liveview_contract.rs
  # reads the same sidecar, and two toolchains that disagree about a contract's
  # identity disagree about whether an app is broken.

  @counter_fingerprint "2d5c38735e3b8e76d12c8fb2fa3de1ad35eac250884ddb417bf59fa7b9787dcf"

  @counter_json ~s({"module":"SpacetimeLvWeb.CounterLive",) <>
                  ~s("events":[{"name":"dec"},{"name":"inc"}],) <>
                  ~s("assigns":[{"name":"count","type":"integer"}],) <>
                  ~s("pushes":[{"name":"flash","fields":{"kind":"atom","message":"string"}}]})

  # The CounterLive contract, as a beam-lisp term. Kept as source text so the
  # test exercises the reader too: a contract that cannot be READ is not a
  # contract, and a hand-built map would skip that half.
  @counter_term ~S"""
  (def counter
    (contract/parse :counter-live
      {:bundle "/spacetime/counter/spacetime.js" :root ".counter"}
      (list
        (quote (assign @count :integer 0))
        (quote (push @flash {:message :string :kind :atom}))
        (quote (on :inc (set! @count (inc @count)) (ok @count)))
        (quote (on :dec (if (zero? @count)
                          (err "Count cannot go below zero")
                          (do (set! @count (dec @count)) (ok @count))))))))
  """

  setup_all do
    BeamLisp.init()
    for f <- ~w(seam contract), do: BeamLisp.Compiler.eval_string(File.read!("priv/#{f}.bl"))
    BeamLisp.Compiler.eval_string(@counter_term)
    :ok
  end

  defp eval(src), do: BeamLisp.Compiler.eval_string(src)

  test "a beam-lisp term reproduces CounterLive's contract JSON byte for byte" do
    assert eval(~s|(contract/contract-json counter "SpacetimeLvWeb.CounterLive")|) ==
             @counter_json
  end

  test "and therefore its fingerprint" do
    assert eval(~s|(contract/fingerprint counter "SpacetimeLvWeb.CounterLive")|) ==
             @counter_fingerprint
  end

  test "declaration order does not change the bytes" do
    # Elixir sorts entries by name, so the fingerprint is a property of the
    # SURFACE, not of how the author happened to order the file.
    eval(~S"""
    (def reordered
      (contract/parse :counter-live
        {:bundle "/spacetime/counter/spacetime.js" :root ".counter"}
        (list
          (quote (on :dec (if (zero? @count)
                            (err "Count cannot go below zero")
                            (do (set! @count (dec @count)) (ok @count)))))
          (quote (push @flash {:message :string :kind :atom}))
          (quote (on :inc (set! @count (inc @count)) (ok @count)))
          (quote (assign @count :integer 0)))))
    """)

    assert eval(~s|(contract/fingerprint reordered "SpacetimeLvWeb.CounterLive")|) ==
             @counter_fingerprint
  end

  test "field values are present, not silently blank" do
    # The regression that byte comparison caught and a structural assertion
    # would not: the first emitter produced {"kind":"","message":""} — correctly
    # shaped JSON with every value empty — by looking keyword keys up with a
    # string. Shape was right; content was gone.
    json = eval(~s|(contract/contract-json counter "SpacetimeLvWeb.CounterLive")|)
    assert json =~ ~s("kind":"atom")
    assert json =~ ~s("message":"string")
    refute json =~ ~s(:"")
  end

  test "reply tags are enumerated from the handler body" do
    # The capability that motivates moving the source of truth to beam-lisp at
    # all. FUP-143: "reply tags live in handler bodies and can be runtime
    # values, so @on_definition cannot soundly enumerate them" — true of Elixir,
    # false of a term.
    assert eval(~s|(seam/reply-tags (seam/handler-for counter "inc"))|) == ["ok"]
    assert eval(~s|(seam/reply-tags (seam/handler-for counter "dec"))|) == ["err", "ok"]
  end

  test "a page missing a receive arm is a named disagreement" do
    # `dec` can answer "err", so a page decoding only "ok" silently drops it.
    # This is the runtime surprise Elixir cannot catch at compile time.
    [d] =
      eval(~S"""
      (seam/disagreements counter {:fires ["dec"] :subscribes [] :arms {:dec ["ok"]}})
      """)
      |> BeamLisp.Vector.to_list()

    assert d[:kind] == :"reply-not-decoded"
    assert d[:event] == "dec"
    assert d[:tag] == "err"
  end

  test "a correct page agrees" do
    assert eval(~S"""
           (seam/agree? counter {:fires ["inc" "dec"]
                                 :subscribes ["count"]
                                 :arms {:inc ["ok"] :dec ["ok" "err"]}})
           """) == true
  end
end
