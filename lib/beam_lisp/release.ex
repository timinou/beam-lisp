defmodule BeamLisp.Release do
  @moduledoc """
  The release VALUE, delegated to the language: `priv/build/release.bl`.

  A Mix release is a tree assembled by a large Elixir module that reads the
  project, the dependency graph, the OTP installation and a pile of templates.
  The drop needs the same tree, so the first question is what goes IN it — and
  that is data, derivable from the running VM:

      %{name: "bl", vsn: "0.1.0",
        erts: %{vsn: "17.0.1", dir: "/usr/lib/erlang"},
        apps: [%{app: :kernel, vsn: "10.0.1", dir: "…/kernel-10.0.1"}, …]}

  The app set is the transitive `:applications` closure of the root app — what
  a release boots, and what `:systools` insists on. Each app's directory comes
  from `:code.lib_dir/1`, which answers for OTP apps and for `_build/<env>/lib`
  dependencies alike, so nothing here reads a dependency file.

  `rel_text/1` writes the classic `Name.rel` term; `write_rel!/2` puts it where
  `systools` looks when it is told `:path` — the release's own directory. The
  assembly stage (the rest of this wave) consumes the value and adds the tree.

  Like `BeamLisp.BuildPlan` and `BeamLisp.BuildLog`, this is the Elixir call
  surface; the logic is in `priv/build/release.bl`. Requires the runtime.
  """

  @ns "release"

  @doc """
  The release value for the root application `app`: name, version, ERTS, and
  the transitive app closure with each app's version and directory.
  """
  @spec value(atom) :: map
  def value(app) when is_atom(app), do: call("value", [app])

  @doc "Every app `app` needs, transitively, in `:applications` order."
  @spec app_closure(atom) :: [atom]
  def app_closure(app) when is_atom(app), do: call("app-closure", [app])

  @doc """
  The apps a release's own boot starts — every app in the value except the
  assembly TOOLS, which are carried on the code path and never started.

  The `.rel` writes an app outside this set as `none`. Not a detail: it is how a
  drop can run `bl self-build` at all (the tool must be present without being
  booted), and it is why `:sasl` appears `none` in a shipped `.rel`.
  """
  @spec app_permanent_set(map) :: MapSet.t()
  def app_permanent_set(value), do: call("app-permanent-set", [value])


  @doc "The `Name.rel` text for a release value (the term `systools` reads)."
  @spec rel_text(map) :: binary
  def rel_text(value), do: call("rel-text", [value])

  @doc """
  Write `value`'s `.rel` into `out/releases/<vsn>/<name>.rel` and return the
  path. `systools` is given the release directory as its `:path`, so this is
  where it must be.
  """
  @spec write_rel!(map, binary) :: binary
  def write_rel!(value, out), do: call("write-rel!", [value, out])

  @doc "The `.rel` path for `name`/`vsn` under `out` (no writing)."
  @spec rel_file(binary, binary, binary) :: binary
  def rel_file(out, name, vsn), do: call("rel-file", [out, name, vsn])

  @doc """
  `rel_text/1` under a chosen name and app TYPE: `start_clean` is the same app
  set with every entry `:none` — on the code path, never started, which is what
  lets `bin/bl eval` reach the release's code without booting it.
  """
  @spec rel_text_for(map, binary, atom) :: binary
  def rel_text_for(value, name, type), do: call("rel-text-for", [value, name, type])

  @doc """
  Assemble the tree for `value` at `out`: every app's `ebin`/`priv` and ERTS,
  the `.rel` and both boot scripts (`make_script` → `$ROOT/lib` →
  `$RELEASE_LIB` → `script2boot`), the Elixir CLI wrappers, the templates, the
  cookie, `start_erl.data`, and `bin/bl`.

  Returns `%{ok?: bool, out: path, apps: n, warnings: n, errors: [msg]}`; a
  `systools` rejection is reported in `errors` rather than raised, because the
  caller is the one that knows whether a tree is required.
  """
  @spec assemble(map, binary) :: map
  def assemble(value, out), do: call("assemble", [value, out])

  defp call(name, args) do
    BeamLisp.Loader.ensure_loaded(@ns)
    BeamLisp.RT.invoke(BeamLisp.Env.fetch!(@ns, name), args)
  end
end
