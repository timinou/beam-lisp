-module('Elixir.BeamLisp.Native.Datom.StoreFjall').
-export([main/0, fjall_open/1, fjall_canonical_path/1, fjall_get/2,
         fjall_range/3, fjall_range_chunk/5, fjall_resolve_chunk/6,
         fjall_count_range/4, fjall_resolve_prefixes/2, fjall_put/3,
         fjall_delete/2, fjall_cas/4, fjall_commit/2, fjall_sync/1,
         fjall_stats/1, keycodec_encode/4, keycodec_key/2,
         keycodec_batch/2, '__nif_loaded__'/0]).

%% A second OS process, not another BEAM process. The stubs are the exact NIF
%% surface declared by priv/lib/datom/store-fjall.bl; no Elixir source or full
%% beam-lisp image is needed to test the per-process ownership lock.
main() ->
    [Lib | Specs] = init:get_plain_arguments(),
    case erlang:load_nif(Lib, 0) of
        ok ->
            run(Specs, 5000, undefined),
            io:format("CHILD-DONE~n"),
            halt(0);
        {error, Reason} ->
            io:format("LOAD-FAILED ~p~n", [Reason]),
            halt(1)
    end.

run([], _HoldMs, _Flag) -> ok;
run([Spec | Rest], HoldMs, Flag) ->
    [Label, Value] = string:split(Spec, "=", leading),
    case Label of
        "holdms" -> run(Rest, list_to_integer(Value), Flag);
        "flag" -> run(Rest, HoldMs, Value);
        "hold" ->
            hold(unicode:characters_to_binary(Value), Flag, HoldMs),
            run(Rest, HoldMs, Flag);
        _ ->
            probe(Label, unicode:characters_to_binary(Value)),
            run(Rest, HoldMs, Flag)
    end.

probe(Label, Path) ->
    try fjall_open(Path) of
        {error, {already_open, Locked}} ->
            io:format("REFUSED ~s already_open ~ts~n", [Label, Locked]);
        {error, Other} ->
            io:format("ERROR ~s ~p~n", [Label, Other]);
        Handle ->
            io:format("OPENED ~s~n", [Label]),
            erlang:phash2(Handle)
    catch Class:Reason ->
        io:format("RAISED ~s ~p:~p~n", [Label, Class, Reason])
    end.

hold(Path, Flag, HoldMs) ->
    try fjall_open(Path) of
        {error, Reason} ->
            io:format("HOLD-FAILED ~p~n", [Reason]);
        Handle ->
            case Flag of
                undefined -> ok;
                _ -> ok = file:write_file(Flag, <<"held">>)
            end,
            io:format("HELD hold~n"),
            timer:sleep(HoldMs),
            %% Keep the resource reachable until AFTER the hold interval.
            erlang:phash2(Handle),
            io:format("RELEASED hold~n")
    catch Class:Reason ->
        io:format("HOLD-FAILED ~p:~p~n", [Class, Reason])
    end.

fjall_open(_) -> erlang:nif_error(nif_not_loaded).
fjall_canonical_path(_) -> erlang:nif_error(nif_not_loaded).
fjall_get(_, _) -> erlang:nif_error(nif_not_loaded).
fjall_range(_, _, _) -> erlang:nif_error(nif_not_loaded).
fjall_range_chunk(_, _, _, _, _) -> erlang:nif_error(nif_not_loaded).
fjall_resolve_chunk(_, _, _, _, _, _) -> erlang:nif_error(nif_not_loaded).
fjall_count_range(_, _, _, _) -> erlang:nif_error(nif_not_loaded).
fjall_resolve_prefixes(_, _) -> erlang:nif_error(nif_not_loaded).
fjall_put(_, _, _) -> erlang:nif_error(nif_not_loaded).
fjall_delete(_, _) -> erlang:nif_error(nif_not_loaded).
fjall_cas(_, _, _, _) -> erlang:nif_error(nif_not_loaded).
fjall_commit(_, _) -> erlang:nif_error(nif_not_loaded).
fjall_sync(_) -> erlang:nif_error(nif_not_loaded).
fjall_stats(_) -> erlang:nif_error(nif_not_loaded).
keycodec_encode(_, _, _, _) -> erlang:nif_error(nif_not_loaded).
keycodec_key(_, _) -> erlang:nif_error(nif_not_loaded).
keycodec_batch(_, _) -> erlang:nif_error(nif_not_loaded).
'__nif_loaded__'() -> erlang:nif_error(nif_not_loaded).
