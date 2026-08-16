defmodule BeamLisp.Spell.Credentials do
  @moduledoc """
  Where a provider key comes from, in one place.

  Three sources, in strict precedence:

      1. the real environment    — `PROVIDER=glm GLM_API_KEY=… mix run …`
      2. `.env` in the cwd        — mode 600, gitignored, the project default set
      3. the agent credential db  — `~/.spell/agent/agent.db`, already holding
                                    keys for the machine's other tools

  ## Why the environment must win

  `.env` is a DEFAULT SET, not an override. An earlier version of this loader
  (copied into four scripts, each subtly different) called `System.put_env/2`
  unconditionally, so `.env`'s `PROVIDER=kimi` silently replaced the
  `PROVIDER=fake` a caller had just exported — and the offline verification path
  could not be selected at all. It failed as "no provider message arrived",
  which reads as a broken stream rather than as a hijacked variable.

  ## Why the db is read at all

  The keys already exist there: the agent stores one per provider, and asking
  someone to copy a key they have already given the machine into a second file
  is friction with no safety benefit. Read-only, and only for a variable that
  is not already set.

  The db is SQLite and this project has no SQLite dependency — adding one to
  read a single row would be the wrong trade, so the `sqlite3` CLI is shelled
  out to. A missing binary, a missing db and a missing row are all the same
  answer here (`nil`), because all three mean the same thing: no key from this
  source, try the next.

  ## Provider → credential row

  The db keys rows by ITS provider names, which are not ours (`zai` is our
  `glm`; `kimi-code` is an OAuth row this project's api-key path cannot use).
  The mapping is explicit rather than derived, so a new provider joins by being
  looked at.
  """

  # Our provider name → {db provider, the env var its key belongs in}.
  #
  # `kimi` is deliberately ABSENT: the db's `kimi-code` row is an OAuth grant,
  # not an api key, and feeding an OAuth access token to a Bearer-api-key path
  # produces a 401 that looks exactly like an expired key. Kimi's key comes
  # from `.env` or the environment.
  @db_providers %{
    "glm" => {"zai", "GLM_API_KEY"},
    "deepseek" => {"deepseek", "DEEPSEEK_API_KEY"}
  }

  @db_path "~/.spell/agent/agent.db"

  @doc """
  Fill in provider credentials from `.env` and the agent db, without ever
  overwriting a variable the caller already set.

  Returns a short list of what it did, for a script that wants to say so.
  """
  def load(opts \\ []) do
    from_file = load_dotenv(Keyword.get(opts, :dotenv, ".env"))
    from_db = load_db()

    from_file ++ from_db
  end

  @doc """
  The api key for `provider` held in the agent db, or nil.

  Public because it is worth being able to ask directly — a script diagnosing
  "is the key even there?" should not have to infer it from an env var that
  several sources could have set.
  """
  def db_key(provider) do
    with {db_provider, _var} <- Map.get(@db_providers, provider),
         path when is_binary(path) <- existing_db(),
         {:ok, key} <- query_key(path, db_provider) do
      key
    else
      _ -> nil
    end
  end

  # ── sources ────────────────────────────────────────────────────────────────

  defp load_dotenv(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n")
        |> Enum.flat_map(&parse_line/1)
        |> Enum.flat_map(fn {k, v} -> put_new(k, v, "#{path}") end)

      # NOT File.read! — three of the four copies of this loader crashed a
      # script that would otherwise have run fine (serving the page, reporting
      # a provider error on a turn) just because the file was absent.
      {:error, _} ->
        []
    end
  end

  defp parse_line(line) do
    case String.split(String.trim(line), "=", parts: 2) do
      [k, v] ->
        k = String.trim(k)
        if k != "" and not String.starts_with?(k, "#"), do: [{k, String.trim(v)}], else: []

      _ ->
        []
    end
  end

  defp load_db do
    Enum.flat_map(@db_providers, fn {provider, {_db_provider, var}} ->
      # Only ask the db for a key that is actually missing: a shell-out per
      # provider on every boot is a cost with no payoff when the variable is
      # already set.
      if System.get_env(var) in [nil, ""] do
        case db_key(provider) do
          nil -> []
          key -> put_new(var, key, "agent db")
        end
      else
        []
      end
    end)
  end

  defp existing_db do
    path = Path.expand(@db_path)
    if File.exists?(path), do: path, else: nil
  end

  defp query_key(path, db_provider) do
    # `json_extract` rather than reading `data` whole: the column is JSON and
    # a raw `select data` renders a redacted form for some rows (`<<$env:…>>`),
    # which looks convincingly like a stored placeholder and is not — it is the
    # CLI's display of the value, and extracting the field returns the real key.
    # Worth naming: a guard was briefly written against that phantom.
    sql =
      "select json_extract(data,'$.key') from auth_credentials " <>
        "where provider='#{db_provider}' and credential_type='api_key' " <>
        "and disabled_cause is null order by updated_at desc limit 1;"

    case System.cmd("sqlite3", [path, sql], stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          "" -> :error
          key -> {:ok, key}
        end

      _ ->
        :error
    end
  rescue
    # `sqlite3` absent — a legitimate state, not an error worth surfacing.
    ErlangError -> :error
  end

  # ── the precedence rule, in one place ──────────────────────────────────────

  defp put_new(key, value, source) do
    if System.get_env(key) in [nil, ""] do
      System.put_env(key, value)
      [{key, source}]
    else
      []
    end
  end
end
