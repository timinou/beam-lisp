defmodule BeamLisp.DepsCompileShim do
  @moduledoc """
  The two Mix functions a DEPENDENCY may ask while it is being read or compiled.

  ## Why this exists

  Some packages read their own project at compile time. `explorer` is the one in
  this lock whose NIF reader does:

      mix_config = Mix.Project.config()
      version = mix_config[:version]
      github_url = mix_config[:package][:links]["GitHub"]
      mode = if Mix.env() in [:dev, :test], do: :debug, else: :release

  and those three values become the base URL of the precompiled artifact the
  package downloads. A toolchain with no Mix cannot answer them by loading Mix —
  and must not answer them by inventing values, which would fetch the wrong
  artifact for the wrong version.

  ## What it answers with

  The package's OWN declaration, evaluated by `deps-compile/project-of` from its
  own `mix.exs` — the same read that produces the `.app` this toolchain writes.
  `Mix.env/0` answers `:prod`, which is the honest answer for a build with no
  `MIX_ENV`; a package that branches on it (test-only support paths, debug
  artifacts) then takes its production branch.

  ## The window is explicit, and closed

  `install!/0` defines both modules in THIS VM; `remove!/0` purges and deletes
  them again, so `Code.ensure_loaded?(Mix)` cannot answer `true` for a caller
  outside the window. That discipline is the whole point: a shim left standing
  would be a lie about the image, and every `Code.ensure_loaded?(Mix)` guard in
  this tree (the AOT output-dir default, the dev-server gate) would take a Mix
  path that does not exist. `deps-compile` calls this from exactly one place,
  with a `finally`.

  NB it is installed rather than conditionally-installed on purpose: deciding by
  scanning sources for the string "Mix." would miss the case where a macro
  expands to the call, and the window costs two tiny modules.
  """

  @project_key :bl_deps_compile_project
  @window_key :bl_deps_compile_window

  # Defined from a string, never in this file's own body: `defmodule Mix.Project`
  # written here would be compiled into the substrate and would shadow the real
  # Mix for the lifetime of every VM this code runs in — including a checkout,
  # where Mix exists and other guards ask about it.
  @source """
  defmodule Mix.Project do
    @moduledoc false
    def config, do: :persistent_term.get(:bl_deps_compile_project, [])
  end

  defmodule Mix do
    @moduledoc false
    def env, do: :prod
  end
  """

  @doc "Define `Mix` and `Mix.Project` for the compile window that follows."
  def install! do
    :persistent_term.erase(@project_key)
    :persistent_term.put(@window_key, true)

    # A CHECKOUT has the real Mix loadable (it ships with Elixir), so defining
    # these two modules there is a redefinition and the compiler says so. The
    # warning is true and unwanted: the redefinition is the design, and
    # `remove!/0` puts the code server back where it was. The option is saved and
    # restored rather than forced, so a caller's own setting survives.
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Code.compile_string(@source)
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end

    :ok
  end

  @doc """
  Publish a package's own `project/0` as the answer to
  `Mix.Project.config/0`.

  Called by `deps-compile/project-of` with what it just read from the package's
  `mix.exs`, so the config a package sees while compiling IS the declaration it
  ships — not a reconstructed subset of it.
  """
  def publish!(project) when is_list(project) do
    :persistent_term.put(@project_key, project)
    :ok
  end

  def publish!(_other), do: :ok

  @doc "Undo `install!/0`: erase the published project, purge and delete both modules."
  def remove! do
    :persistent_term.erase(@project_key)
    :persistent_term.erase(@window_key)

    for mod <- [Mix.Project, Mix] do
      :code.purge(mod)
      :code.delete(mod)
    end

    :ok
  end

  @doc "Whether a compile window is open (used by tests and by `deps-compile`'s own assertion)."
  def installed? do
    :persistent_term.get(@window_key, false)
  end
end
