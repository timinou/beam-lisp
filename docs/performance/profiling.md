# Profiling a Beam Lisp program

```clojure
(require '[bl.profile :as profile])

(profile/print! (profile/call-time (fn [] (render page))))          ; this process
(profile/print! (profile/call-time (fn [] (transact! c tx)) {:all? true}) 20)
```

`call-time` runs the thunk once under OTP `tprof` (call_time) and returns
`{:value :total-us :profiled? :rows}`. Rows are named in **Beam Lisp terms**:

- `Elixir.BeamLisp.Ns[.Body|.Init].Reception.Ui.Screens` → `reception.ui.screens`
  (a namespace's companion modules are one unit);
- `-work-row/3-anonymous-2-` → `work-row` (a closure is charged to the named
  function enclosing it);
- runtime modules keep their own rows, marked `[runtime]` (`LazyMemo/deps_walk`,
  `Env/ns_ready_in?`, …), so an expensive runtime path shows up as itself.

Use `{:all? true}` when the work runs in another process (a GenServer call: a
datom writer, an owner server). It traces every process and slows the VM while
it runs.

Releases carry OTP's `tools` application (`build.release/tool-apps`) on the code
path, unstarted; a checkout uses the host OTP's. Without it `call-time` still
returns the value and total time, with `:profiled? false`.
