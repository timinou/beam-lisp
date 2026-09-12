import Config

# Diagnostics go to stderr; stdout carries only the program's DATA.
#
# Every `bl` verb that takes `--json` promises one JSON object on stdout, and
# `bl run`/`bl eval` promise the program's own output there. Elixir's default
# logger handler writes to standard_io, so one library log line — `Bandit`
# announces every listener it starts, the daemon logs its lifecycle — was
# enough to interleave prose into a machine-read stream.
#
# This is the handler's PRIMARY config, which `logger_std_h` refuses to change
# while the handler is running (`{:illegal_config_change, …}`); it has to be set
# at boot, which is exactly what this file does — for the dev runtime, the test
# runtime, and the release the drop ships.
config :logger, :default_handler, config: %{type: :standard_error}
