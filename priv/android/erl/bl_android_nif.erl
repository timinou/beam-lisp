%% bl_android_nif — the BEAM half of the JVM seam (see bl_android_nif.c).
%%
%% Statically linked into the app's .so: `load_nif` resolves through the
%% driver table, so the path argument is only a name. Off-device (the desk, a
%% test VM) the load fails and every function answers {error, not_on_android}
%% instead of crashing, so android.* namespaces load anywhere and say plainly
%% why a call cannot run.
-module(bl_android_nif).
-export([call/1, attached/0]).
-on_load(init/0).

init() ->
    _ = erlang:load_nif("bl_android_nif", 0),
    ok.

call(_Json) -> {error, not_on_android}.
attached() -> false.
