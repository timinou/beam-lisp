defmodule BeamLisp.Spell.CredentialsTest do
  # What is pinned here is PRECEDENCE, because getting it backwards is what the
  # four hand-copied loaders this module replaced actually did: they overrode
  # the real environment, so `PROVIDER=fake mix run …` silently ran against a
  # paid provider named in `.env`. That failed as "no provider message
  # arrived", which reads as a broken stream rather than a hijacked variable.
  use ExUnit.Case, async: false

  alias BeamLisp.Spell.Credentials

  @var "BEAMLISP_CREDENTIALS_TEST_KEY"

  setup do
    System.delete_env(@var)
    on_exit(fn -> System.delete_env(@var) end)
    :ok
  end

  defp write_env(contents) do
    path = Path.join(System.tmp_dir!(), "credtest-#{System.unique_integer([:positive])}.env")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "the environment wins" do
    test "a variable already set is never replaced by the file" do
      System.put_env(@var, "from-the-caller")
      path = write_env("#{@var}=from-the-file\n")

      loaded = Credentials.load(dotenv: path)

      assert System.get_env(@var) == "from-the-caller"
      refute Enum.any?(loaded, fn {k, _} -> k == @var end)
    end

    test "an EMPTY variable is treated as unset, not as a deliberate blank" do
      # `FOO= mix run …` is how a shell says "I don't have one", not "use the
      # empty string as a key" — a blank would reach the provider as
      # `Bearer `, whose 401 is indistinguishable from a wrong key.
      System.put_env(@var, "")
      path = write_env("#{@var}=from-the-file\n")

      Credentials.load(dotenv: path)

      assert System.get_env(@var) == "from-the-file"
    end
  end

  describe "the file" do
    test "sets a variable that is absent, and reports the source" do
      path = write_env("#{@var}=from-the-file\n")

      loaded = Credentials.load(dotenv: path)

      assert System.get_env(@var) == "from-the-file"
      assert {@var, source} = Enum.find(loaded, fn {k, _} -> k == @var end)
      assert source =~ "credtest"
    end

    test "skips comments and blank lines" do
      path = write_env("# #{@var}=commented\n\n   \n#{@var}=real\n")

      Credentials.load(dotenv: path)

      assert System.get_env(@var) == "real"
    end

    test "keeps '=' inside a value" do
      # base64 and padded tokens contain '='; splitting on every one of them
      # truncates the credential into something that fails authentication for
      # a reason nobody would guess from the error.
      path = write_env("#{@var}=abc==def=\n")

      Credentials.load(dotenv: path)

      assert System.get_env(@var) == "abc==def="
    end

    test "a missing file is not an error" do
      # Three of the four replaced loaders used File.read!, so a script that
      # would otherwise run fine (serving the page, reporting a provider error
      # on a turn) crashed at boot over an optional file.
      assert Credentials.load(dotenv: "/nonexistent/definitely/.env") |> is_list()
    end
  end

  describe "the agent db" do
    test "an unknown provider has no db credential" do
      assert Credentials.db_key("no-such-provider") == nil
    end

    test "kimi is deliberately not sourced from the db" do
      # The db's `kimi-code` row is an OAuth grant, not an api key. Feeding an
      # OAuth access token to a Bearer-api-key path yields a 401 that looks
      # exactly like an expired key.
      assert Credentials.db_key("kimi") == nil
    end

    @tag :live_credentials
    test "glm resolves to a usable-looking key when the db has one" do
      # Tagged: it depends on this machine's agent db. Excluded by default so
      # the suite stays hermetic; run with `--include live_credentials`.
      case Credentials.db_key("glm") do
        nil -> :ok
        key -> assert byte_size(key) > 20
      end
    end
  end
end
