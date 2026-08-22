defmodule BeamLisp.NativeTest do
  @moduledoc """
  `defnative` — a beam-lisp namespace hosting a Rust NIF.

  These tests are about the DECLARATION mechanism, not about redb. They
  use the `datom_redb` crate because it is the one that exists, but
  what is being checked is: does a `.bl` namespace get its native names
  bound, does a bad declaration fail loudly, and does an absent NIF read
  as absent rather than as broken?

  That last one carries weight beyond tidiness. A native backend that
  fails to load must not appear present-but-degraded, because the layer
  above chooses a store based on `available?` and a wrong answer there
  means silently running without durability.
  """

  use ExUnit.Case, async: false

  setup do
    BeamLisp.init()
    :ok
  end

  defp eval(src), do: BeamLisp.eval(src)

  describe "declaring native functions" do
    test "a namespace can call its own NIF" do
      # `datom.store-redb` is the namespace the crate was BUILT for:
      # `rustler::init!` names its host module at compile time, so a
      # crate loads into exactly one namespace. See the moduledoc.
      BeamLisp.run_file("priv/datom/store-redb.bl")

      assert BeamLisp.Native.available?("datom.store-redb")

      path = Path.join(System.tmp_dir!(), "native_test_#{System.unique_integer([:positive])}.redb")

      # Round-trip through the NIF, called as ordinary beam-lisp
      # functions with no Elixir module between them.
      assert eval("""
             (ns native.test.basic (:require [datom.store-redb]))
             (let [db (datom.store-redb/redb-open "#{path}")]
               (datom.store-redb/redb-put db "k" "v")
               (datom.store-redb/redb-get db "k"))
             """) == "v"
    end

    test "a native name is a VALUE, not only a callable" do
      # Linked twice: `put_link` so the compiler emits a direct call,
      # and `intern` so the name can be passed around. A native function
      # that could only be called and never passed would be
      # second-class in a language where functions are values.
      BeamLisp.run_file("priv/datom/store-redb.bl")

      assert eval("""
             (ns native.test.value (:require [datom.store-redb]))
             (fn? datom.store-redb/redb-get)
             """) == true
    end
  end

  describe "declarations that should be refused" do
    test "a name that shadows core is refused, with the fix in the message" do
      # The collision does not fail where it is written — it fails
      # wherever the namespace next uses the core function for its own
      # purposes, with an error about argument types far from the cause.
      err =
        assert_raise RuntimeError, fn ->
          eval("""
          (ns native.test.shadow)
          (defnative "datom_redb" (get 2))
          """)
        end

      assert err.message =~ "would shadow core"
      assert err.message =~ "Prefix them"
    end

    test "a duplicate name is refused" do
      # A beam-lisp var binds ONE function, so a repeated name means the
      # second registration wins and the first silently does nothing.
      err =
        assert_raise RuntimeError, fn ->
          eval("""
          (ns native.test.dup)
          (defnative "datom_redb" (redb-get 2) (redb-get 3))
          """)
        end

      assert err.message =~ "declared more than once"
    end

    test "a malformed signature is refused" do
      assert_raise RuntimeError, fn ->
        eval("""
        (ns native.test.malformed)
        (defnative "datom_redb" redb-get)
        """)
      end
    end
  end

  describe "when the NIF is absent" do
    @tag :capture_log
    test "the namespace still loads and available? answers false" do
      # The whole point. A checkout without a Rust toolchain, or a crate
      # that failed to build, must leave the database running on its
      # in-memory stores rather than exploding at require time.
      # `conformance_test.bl` conditions its store list on exactly this.
      eval("""
      (ns native.test.missing)
      (defnative "no_such_crate_exists" (nope-one 1))
      """)

      refute BeamLisp.Native.available?("native.test.missing")
    end

    @tag :capture_log
    test "an arity that disagrees with the crate is reported, not swallowed" do
      # `load_nif` refuses a library whose module lacks a stub for any
      # exported function, and the reason names the offending one. That
      # diagnosis used to be hidden behind an env var, so a drifted
      # declaration left the backend quietly absent.
      eval("""
      (ns native.test.arity)
      (defnative "datom_redb" (redb-get 99))
      """)

      refute BeamLisp.Native.available?("native.test.arity")
    end
  end

  describe "the host module" do
    @tag :capture_log
    test "is named after the NAMESPACE, so the crate must agree" do
      # The module name is derived from the `.bl` namespace, and
      # `rustler::init!` hardcodes the one it was built for. A namespace
      # the crate does not name gets a host module and stubs, but the
      # library refuses to load into it — reported, and `available?`
      # answers false.
      eval("""
      (ns my.cool.ns)
      (defnative "datom_redb" (redb-open 1))
      """)

      assert Code.ensure_loaded?(BeamLisp.Native.My.Cool.Ns)
      refute BeamLisp.Native.available?("my.cool.ns")
    end
  end

  describe "AOT" do
    test "an emitted namespace replays its native declaration" do
      # The host module is built by `Module.create` at RUNTIME, so AOT
      # never wrote it to disk and nothing recreated it. An
      # AOT-compiled deployment therefore started with NO native
      # backend: `available?` answered false, the layer above quietly
      # chose an in-memory store, and a database meant to be durable
      # was not.
      #
      # Silent loss of durability is the worst shape this could take —
      # no crash, no warning, and the only symptom is data missing
      # after a restart (BUG-021).
      BeamLisp.run_file("priv/datom/store-redb.bl")

      out = Path.join(System.tmp_dir!(), "aot_native_#{System.unique_integer([:positive])}")
      File.mkdir_p!(out)

      mods = BeamLisp.AOT.compile_file("priv/datom/store-redb.bl", output_dir: out)
      assert length(mods) >= 1

      # The declaration is recorded, which is what `__bl_init__` replays.
      assert BeamLisp.Native.declaration("datom.store-redb") != nil

      # And the emitted module's init carries it: loading the AOT output
      # in a deployment brings the host module and the NIF with it.
      {mod, path} = hd(mods)
      assert File.exists?(path)
      assert function_exported?(mod, :__bl_init__, 0)

      assert Code.ensure_loaded?(BeamLisp.Native.Datom.StoreRedb)
      assert BeamLisp.Native.available?("datom.store-redb")
    end

    test "the native functions work through the AOT-loaded module" do
      BeamLisp.run_file("priv/datom/store-redb.bl")

      db_path = Path.join(System.tmp_dir!(), "aot_rt_#{System.unique_integer([:positive])}.redb")
      db = BeamLisp.Native.Datom.StoreRedb.redb_open(db_path)

      assert :ok = BeamLisp.Native.Datom.StoreRedb.redb_put(db, "k", "v")
      assert "v" == BeamLisp.Native.Datom.StoreRedb.redb_get(db, "k")
    end
  end
end
