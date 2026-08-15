defmodule SpellWeb.ChatLive do
  @moduledoc """
  A PLACEHOLDER for the module the contract generates.

  `spell.contract/elixir-module` emits the real `SpellWeb.ChatLive` from the
  chat contract, and `scripts/serve_live.exs` compiles it at boot — replacing
  this module in the code server. This file exists so that `mix compile` and the
  router have a module of that name before the generator has ever run, and so a
  request that arrives BEFORE generation gets an honest answer instead of an
  undefined-function crash.

  It deliberately does not fake the seam: it declares no events, so nothing here
  can silently answer a signal the real contract would have handled differently.
  Its only job is to say which state you are looking at.

  If you are reading this in a browser, the boot script has not generated the
  server half yet — run `mix run --no-halt scripts/serve_live.exs`.
  """

  use Spacetime.LiveView,
    bundle: "/spacetime/spacetime.js",
    root: ".chat",
    shell: "<main class='chat'><div class='log' data-log></div></main>"

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_event(event, _payload, socket) do
    {:reply,
     %{
       tag: "err",
       reply:
         "the server half has not been generated yet (#{event}); " <>
           "run: mix run --no-halt scripts/serve_live.exs"
     }, socket}
  end
end
