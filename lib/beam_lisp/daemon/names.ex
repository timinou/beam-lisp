defmodule BeamLisp.Daemon.Names do
  @moduledoc """
  The name a port answers to.

  A project's ports have names — `:ports {:web 0 :admin 0}` in `env.bl` — and a
  name is what a developer types, links and opens. This module turns a port's
  name into the HOST that carries it, so the number the OS chose stays where it
  belongs: in the registry, out of every URL a human touches.

      host(root, "web")  →  "web.pulse.test"
      host(root, :ui)    →  "pulse.test"          the session's own address
      hosts(root, "web") →  ["web.pulse.test", "web.pulse.localhost"]

  ## The rule

      <port-name>.<base>.<suffix>       and, for :ui, <base>.<suffix>

      base = slug(project :name, else the directory's own name)
             <> "-" <> slug(instance)   when the tree has an instance

  The instance is `:instance` when `env.bl` declares one, else the tree's git
  branch when that branch is not a default one. Two checkouts of one project
  therefore do not fight over one name unless they are both on `main` — and even
  then the registry refuses the second claim BY NAME rather than quietly binding
  somewhere else (see `BeamLisp.Daemon.Ports`).

  ## Two suffixes, one route

  Every host is offered under `.test` and `.localhost`. `.test` is the reserved
  testing TLD — a host can point it at loopback with one dnsmasq line
  (`address=/test/127.0.0.1`). `.localhost` needs no resolver at all:
  nss-myhostname and every browser answer it. Whichever spelling a machine
  resolves, the gateway answers the same route, so no install is on the critical
  path of a first run.

  ## What this module is not

  It binds nothing and knows nothing about which ports are live. Naming is a
  pure function of the tree and the port's name; the registry
  (`BeamLisp.Daemon.Ports`) holds the number, and `BeamLisp.Daemon.Gateway`
  routes to it.
  """

  @own_port_names ~w(ui)
  @default_branches ~w(main master trunk HEAD)
  @default_suffixes ~w(test localhost)
  # A DNS label is 63 bytes. Long names are truncated rather than refused: the
  # name is for a human, and a refused claim over a long branch would be a
  # worse trade than a shorter name.
  @max_label 63
  @fallback_base "app"

  @doc """
  The host suffixes offered, nearest first. `BL_NAMES_SUFFIXES` (colon
  separated) replaces the default pair, for a host where only one of the two
  resolves.
  """
  def suffixes do
    case System.get_env("BL_NAMES_SUFFIXES") do
      v when is_binary(v) and v != "" ->
        v |> String.split(":", trim: true) |> Enum.map(&slug/1) |> Enum.reject(&(&1 == ""))

      _ ->
        @default_suffixes
    end
  end

  @doc """
  Every host the port named `port_name` answers to for the tree at `root`,
  in the order they should be printed. Empty when the port has no usable name.
  """
  def hosts(root, port_name) do
    base = base(root)

    label =
      case label(port_name) do
        nil -> base
        l -> l <> "." <> base
      end

    Enum.map(suffixes(), &(label <> "." <> &1))
  end

  @doc "The first host for `port_name` — the one to print."
  def host(root, port_name) do
    case hosts(root, port_name) do
      [h | _] -> h
      [] -> nil
    end
  end

  @doc """
  The base label for the tree at `root`: the project's name, qualified by the
  instance it is running as. Always a single DNS label — a project named
  `my.app` answers as `my-app`.
  """
  def base(root) do
    project = project(root)

    name =
      case Map.get(project, :name) do
        s when is_binary(s) and s != "" -> s
        _ -> Path.basename(Path.expand(root))
      end

    case instance(project, root) do
      nil -> nonempty(slug(name))
      i -> nonempty(slug(name)) <> "-" <> slug(i)
    end
  end

  @doc """
  The instance label for the tree at `root`, or nil: `:instance` from `env.bl`
  when it declares one, else the git branch when it is not a default branch.
  """
  def instance(project, root) do
    case Map.get(project, :instance) do
      s when is_binary(s) and s != "" -> nonempty(slug(s), nil)
      _ -> branch(root)
    end
  end

  @doc """
  A DNS label made of `s`: lowercased, runs of anything else folded to one `-`,
  trimmed, truncated to 63. Empty when `s` has nothing usable in it.
  """
  def slug(s) when is_binary(s) do
    s
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, @max_label)
    |> String.trim_trailing("-")
  end

  def slug(nil), do: ""
  def slug(other), do: slug(to_string(other))

  @doc """
  The label a port name contributes, or nil when the port IS the session's own
  address and contributes none (`:ui` answers at the bare base).
  """
  def label(port_name) do
    s = to_string(port_name)

    if s in @own_port_names do
      nil
    else
      case slug(s) do
        "" -> nil
        l -> l
      end
    end
  end

  # --- internals ---

  # The project value, read through the ONE reader of env.bl (`bl.env/project`)
  # rather than a second parser here. A tree with no env.bl, or one whose file
  # cannot be read, is not an error for naming: it gets a name from its
  # directory instead.
  defp project(root) do
    BeamLisp.Loader.ensure_loaded("bl.env")

    case BeamLisp.RT.invoke(BeamLisp.Env.fetch!("bl.env", "project"), [root]) do
      %{} = p -> p
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  # The tree's git branch, when it is not one a second checkout would also be
  # on. Detached HEAD reads as "HEAD"; a directory that is not in a repository
  # makes git fail — both are simply "no instance".
  defp branch(root) do
    case System.cmd("git", ["-C", root, "rev-parse", "--abbrev-ref", "HEAD"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        b = String.trim(out)

        cond do
          b == "" -> nil
          b in @default_branches -> nil
          String.starts_with?(b, "-") -> nil
          true -> nonempty(slug(b), nil)
        end

      _ ->
        nil
    end
  rescue
    # no git on PATH, or a directory that vanished under us
    _ -> nil
  end

  defp nonempty(s, fallback \\ @fallback_base) do
    case s do
      "" -> fallback
      s -> s
    end
  end
end
