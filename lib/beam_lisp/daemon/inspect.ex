defmodule BeamLisp.Daemon.Inspect do
  @moduledoc """
  The session's read-model: everything a view of a warm session needs, in one
  value, built once per request.

  The rule this exists to keep is `reload.monitor`'s, made universal: the
  terminal and the browser never disagree, because there is one model and two
  renderers. `bl daemon status` renders this; the session page renders this; the
  JSON endpoint serves this. A pane added to one is a field added here.

  The model answers, in one map:

    * identity    — the tree, its pid, its age, the compiler key it booted with
    * ports       — every live claim, whoever made it
    * tasks       — what the project declares (`env.bl`)
    * queue       — the single worker's depth: is the session busy right now
    * image       — the reload read-model (`reload/inspect`), when the language
                    side is loaded: namespaces, vars, the reload journal

  `image` is reached through the runtime, not reimplemented here: the language
  owns what the language knows. When it is unavailable (a daemon that never
  loaded reload), the key is simply absent — the model describes what it has
  rather than pretending to have everything.
  """

  alias BeamLisp.Daemon.{Ports, Server}

  @doc """
  The model for the running daemon. Cheap enough to call per request: one
  Agent read for identity, one directory scan for ports, one `env.bl` read for
  tasks, and the reload read-model only when it is already loaded.
  """
  def model(opts \\ []) do
    status = status(opts)
    root = Map.get(status, :root) || File.cwd!()

    %{
      identity: identity(status, root),
      ports: ports(),
      tasks: tasks(root),
      queue: queue(),
      image: image(opts)
    }
  end

  @doc """
  The model as JSON-safe data — string keys, no structs, no pids as terms. The
  HTTP face serves exactly this, so a client sees what the page sees.
  """
  def json(opts \\ []) do
    m = model(opts)

    %{
      "identity" => stringify(m.identity),
      "ports" => Enum.map(m.ports, &stringify/1),
      "tasks" => Enum.map(m.tasks, &stringify/1),
      "queue" => stringify(m.queue),
      "image" => m[:image] && stringify(m.image)
    }
  end

  # --- the parts ---

  defp identity(status, root) do
    %{
      root: root,
      name: Path.basename(root),
      tree_id: Map.get(status, :tree_id),
      pid: Map.get(status, :pid),
      uptime_ms: Map.get(status, :uptime_ms),
      compiler_key: Map.get(status, :compiler_key),
      daemon_build_id: Map.get(status, :daemon_build_id),
      started_at: Map.get(status, :started_at)
    }
  end

  defp ports do
    # The live facts are asked ONCE for the whole render: `Gateway.live/0`
    # returns the gateway's port and whether port 80 answers for it. Asking per
    # row would read the runtime dir and probe port 80 once per named port —
    # round trips that queue behind every other file operation in this VM (a
    # single dirty-IO scheduler), which is how drawing a page turns into a
    # client timeout.
    live = BeamLisp.Daemon.Gateway.live()

    Enum.map(Ports.list(), fn p ->
      # The claim carries the names it answers to, so the model reads them
      # rather than deriving anything: one place decides what a port is
      # CALLED, and it is the process that holds the port.
      hosts = Map.get(p, :hosts, [])

      %{
        name: p.name,
        port: p.port,
        hosts: hosts,
        root: p.root,
        tree_id: p.tree_id,
        pid: p.pid,
        url: named_url(hosts, p.port, live),
        loopback: "http://127.0.0.1:#{p.port}/",
        claimed_at: p.claimed_at
      }
    end)
  end

  # The address a human keeps, and — when a port has no name — the address
  # that is always true. The port rule itself lives in `Gateway.url/3`: an
  # address that omits the port nothing is listening on looks clickable and
  # answers `connection refused`.
  defp named_url([host | _], _port, %{port: port, fronted: fronted}),
    do: BeamLisp.Daemon.Gateway.url(host, port, fronted)

  defp named_url([], port, _live), do: "http://127.0.0.1:#{port}/"

  defp tasks(root) do
    project = project(root)
    declared = Map.get(project, :tasks, %{}) || %{}

    Enum.map(declared |> Map.keys() |> Enum.sort(), fn name ->
      spec = Map.get(declared, name, %{})

      %{
        name: name,
        run: Map.get(spec, :run, ""),
        doc: Map.get(spec, :doc) || "",
        watch: Map.get(spec, :watch, false),
        paths: Map.get(spec, :paths, [])
      }
    end)
  end

  defp queue do
    %{depth: depth()}
  end

  defp depth do
    BeamLisp.Daemon.Executor.queue_depth()
  rescue
    _ -> 0
  end

  # The reload read-model, only when the language side has it loaded: asking a
  # daemon that never loaded `reload` to produce one would mean loading it here,
  # which is work nobody asked for.
  defp image(_opts) do
    if BeamLisp.Env.loaded_ns?("reload") do
      BeamLisp.RT.invoke(BeamLisp.Env.fetch!("reload", "inspect"), [])
    end
  rescue
    _ -> nil
  end

  defp project(root) do
    BeamLisp.Loader.ensure_loaded("bl.env")

    case BeamLisp.RT.invoke(BeamLisp.Env.fetch!("bl.env", "project"), [root]) do
      %{} = p -> p
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp status(opts) do
    case Keyword.get(opts, :status_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Server.status()
    end
  rescue
    _ -> %{root: File.cwd!(), pid: nil, uptime_ms: 0}
  end

  # --- JSON shaping ---

  # A STRUCT is a map too (it carries :__struct__), and beam-lisp's values are
  # structs: Vector, Set, LazySeq, Atom, Ref … Taking the map path with one
  # would enumerate its FIELDS as if they were the data. So the map clause
  # excludes structs, and a struct is rendered by `inspect` — the read-model's
  # JSON face describes beam-lisp values, it does not disassemble them.
  defp stringify(m) when is_map(m) and not is_struct(m) do
    Map.new(m, fn {k, v} -> {to_string(k), jsonable(v)} end)
  end

  defp stringify(other), do: jsonable(other)

  defp jsonable(v) when is_pid(v), do: inspect(v)
  defp jsonable(v) when is_struct(v), do: inspect(v)
  defp jsonable(v) when is_atom(v) and is_boolean(v), do: v
  defp jsonable(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp jsonable(v) when is_list(v), do: Enum.map(v, &jsonable/1)
  defp jsonable(m) when is_map(m) and not is_struct(m), do: stringify(m)
  defp jsonable(v) when is_tuple(v), do: inspect(v)
  defp jsonable(v), do: v

  # --- rendering: the terminal face of the same model ---

  @doc """
  The model as the terminal's text — the face `bl daemon status` shows. Rendered
  from the model rather than gathered separately, so the two faces are two
  renderings and not two truths.
  """
  def render_text(m) do
    id = m.identity

    """
    bl daemon
      tree          #{id.name}  (#{id.root})
      pid           #{id.pid}
      tree_id       #{id.tree_id}
      compiler_key  #{id.compiler_key || "(none)"}
      build_id      #{id.daemon_build_id || "(none)"}
      uptime_ms     #{id.uptime_ms}
    #{render_ports(m.ports)}
    #{render_tasks(m.tasks)}
    #{render_queue(m.queue)}#{render_image(m[:image])}
    """
  end

  defp render_ports([]), do: "  ports         (none claimed)"

  defp render_ports(ports) do
    Enum.map_join(ports, "\n", fn p ->
      "  port          #{p.name} = #{p.url}  → #{p.port}  (#{Path.basename(p.root)}, pid #{p.pid})"
    end) <> ports_urls(ports)
  end

  defp ports_urls(ports) do
    case Enum.find(ports, fn p -> p.name == "ui" end) do
      nil ->
        ""

      ui ->
        "\n  ui            #{ui.url}\n" <>
          "  mcp           #{ui.url}mcp  (the same MCP `bl mcp` serves over stdio)"
    end
  end

  defp render_tasks([]), do: "  tasks         (this tree declares none)"

  defp render_tasks(tasks) do
    Enum.map_join(tasks, "\n", fn t ->
      "  task          #{t.name}#{if t.doc != "", do: "  — " <> t.doc, else: ""}" <>
        "#{if t.watch, do: "  [watch]", else: ""}"
    end)
  end

  defp render_queue(%{depth: d}), do: "  queue_depth   #{d}"

  defp render_image(nil), do: ""

  defp render_image(image) do
    case BeamLisp.Env.fetch("reload.monitor", "render-text") do
      {:ok, render} ->
        "\n" <> to_string(BeamLisp.RT.invoke(render, [image]))

      _ ->
        ""
    end
  rescue
    _ -> ""
  end
end
