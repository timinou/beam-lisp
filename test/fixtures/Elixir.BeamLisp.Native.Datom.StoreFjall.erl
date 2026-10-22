-module('Elixir.BeamLisp.Native.Datom.StoreFjall').
-export([main/0]).
%% NIF_EXPORTS

%% A second OS process, not another BEAM process. The parent generates stubs from its actual loaded NIF
%% module exports; no Elixir source or full
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

%% NIF_STUBS
