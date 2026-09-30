# store_lock_child.exs — the SECOND OS process for the store-exclusivity gate.
#
# usage: elixir store_lock_child.exs LIB_WITHOUT_SO SPEC [SPEC ...]
#
# SPEC is `label=value`. Each probe prints one line:
#   OPENED  <label>                     the store was free and this process owns it
#   REFUSED <label> already_open <dir>  another OS process owns it (typed)
#   ERROR   <label> <reason>            some other native failure
#   RAISED  <label> <message>           the call itself failed
# and the two hold controls are:
#   hold=<path>    open <path> and keep it open until this process exits
#   holdms=<n>     how long to hold it (default 5000)
#   flag=<path>    create this file once the hold is ACQUIRED, so the parent
#                  never has to poll a lock it cannot see
# The run ends with CHILD-DONE.
#
# WHY A BARE `elixir` VM RATHER THAN `bl run`. The gate is about the native
# contract, and the load happens through the SAME artifact the parent is running
# (`vm.native/lib-path`, passed in), so a second OS process costs about a second
# instead of a whole beam-lisp image. Being a different VM is the point: `flock`
# is per-process, so this really is another owner.
#
# The stub list mirrors priv/lib/datom/store-fjall.bl's `(defnative
# "datom_fjall" …)` block. The VM refuses a NIF library whose entry names a
# function the calling module does not export, so every declared NIF needs a
# stub; a newly declared one surfaces here as a loud LOAD-FAILED naming it.
[lib | specs] = System.argv()

source = """
defmodule BeamLisp.Native.Datom.StoreFjall do
  @on_load :__bl_load
  def __bl_load, do: :erlang.load_nif(~c"#{lib}", 0)
  def fjall_open(_a), do: :erlang.nif_error(:nif_not_loaded)
  def fjall_canonical_path(_a), do: :erlang.nif_error(:nif_not_loaded)
  def fjall_get(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
  def fjall_range(_a, _b, _c), do: :erlang.nif_error(:nif_not_loaded)
  def fjall_range_chunk(_a, _b, _c, _d, _e), do: :erlang.nif_error(:nif_not_loaded)
  def fjall_resolve_chunk(_a, _b, _c, _d, _e, _f), do: :erlang.nif_error(:nif_not_loaded)
  def fjall_count_range(_a, _b, _c, _d), do: :erlang.nif_error(:nif_not_loaded)
  def fjall_resolve_prefixes(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
  def fjall_put(_a, _b, _c), do: :erlang.nif_error(:nif_not_loaded)
  def fjall_delete(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
  def fjall_cas(_a, _b, _c, _d), do: :erlang.nif_error(:nif_not_loaded)
  def fjall_commit(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
  def fjall_sync(_a), do: :erlang.nif_error(:nif_not_loaded)
  def fjall_stats(_a), do: :erlang.nif_error(:nif_not_loaded)
  def keycodec_encode(_a, _b, _c, _d), do: :erlang.nif_error(:nif_not_loaded)
  def keycodec_key(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
  def keycodec_batch(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
  def __nif_loaded__, do: :erlang.nif_error(:nif_not_loaded)
end
"""

try do
  Code.compile_string(source)
rescue
  e -> IO.puts("LOAD-FAILED #{Exception.message(e)}")
end

probe = fn label, path ->
  try do
    case BeamLisp.Native.Datom.StoreFjall.fjall_open(path) do
      {:error, {:already_open, locked}} -> IO.puts("REFUSED #{label} already_open #{locked}")
      {:error, other} -> IO.puts("ERROR #{label} #{inspect(other)}")
      _handle -> IO.puts("OPENED #{label}")
    end
  rescue
    e -> IO.puts("RAISED #{label} #{Exception.message(e)}")
  end
end

Enum.each(specs, fn spec ->
  [label, value] = String.split(spec, "=", parts: 2)

  cond do
    label == "holdms" ->
      Process.put(:holdms, String.to_integer(value))

    label == "flag" ->
      Process.put(:flag, value)

    label == "hold" ->
      try do
        handle = BeamLisp.Native.Datom.StoreFjall.fjall_open(value)

        case Process.get(:flag) do
          nil -> :ok
          flag -> File.write!(flag, "held")
        end

        IO.puts("HELD hold")
        Process.sleep(Process.get(:holdms, 5000))
        # Referenced AFTER the sleep: the handle, and with it the lock, has to
        # live exactly as long as this process does.
        _ = handle
        IO.puts("RELEASED hold")
      rescue
        e -> IO.puts("HOLD-FAILED #{Exception.message(e)}")
      end

    true ->
      probe.(label, value)
  end
end)

IO.puts("CHILD-DONE")
