alias BeamLisp.Spell.Live
{:ok, _} = Live.start_link(out: "/tmp/live-probe")

IO.puts("v#{Live.state().version} at start; views: #{inspect(Live.state().machine["views"])}")

good = %{
  "kind" => "view", "name" => "clock", "rationale" => "show a clock",
  "templates" => [%{"name" => "clockface", "html" => "<div class='clock'>{@m.text}</div>"}],
  "style" => [%{"selector" => ".clock", "rules" => %{"font-size" => "2rem"}}],
  "binds" => [%{"selector" => ".clock", "each" => %{"binding" => "messages", "as" => "m", "template" => "clockface"}}]
}

r1 = Live.define(good)
IO.puts("ACCEPT → #{r1.status}; v#{Live.state().version}; views: #{inspect(Live.state().machine["views"])}")

bad = %{
  "kind" => "view", "name" => "ghost", "rationale" => "bind a name nobody publishes",
  "templates" => [%{"name" => "row", "html" => "<li class='row'>{@r.t}</li>"}],
  "binds" => [%{"selector" => ".row", "each" => %{"binding" => "nothing", "as" => "r", "template" => "row"}}]
}

before = Live.state()
r2 = Live.define(bad)
after_ = Live.state()
IO.puts("REJECT → #{r2.status} at #{inspect(r2[:rung])}: #{String.slice(inspect(r2[:reason]), 0, 90)}")
IO.puts("machine unchanged: #{before.machine == after_.machine}; version unchanged: #{before.version == after_.version}")

ghosty = %{
  "kind" => "view", "name" => "ghosty", "rationale" => "styles a class nothing renders",
  "templates" => [%{"name" => "real", "html" => "<i class='real'>{@m.text}</i>"}],
  "style" => [%{"selector" => ".real", "rules" => %{"color" => "#fff"}},
              %{"selector" => ".phantom", "rules" => %{"color" => "#f00"}}],
  "binds" => [%{"selector" => ".real", "each" => %{"binding" => "messages", "as" => "m", "template" => "real"}}]
}
r3 = Live.define(ghosty)
IO.puts("GHOST → #{r3.status} at #{inspect(r3[:rung])}: #{String.slice(to_string(r3[:reason]), 0, 100)}")

IO.puts("report.json: #{File.exists?("/tmp/live-probe/report.json")}, bundle: #{File.exists?("/tmp/live-probe/spacetime.js")}")
