-module(p0run).
-export([go/0]).
go() ->
    application:ensure_all_started(elixir),
    catch 'Elixir.BeamLisp':init(),
    Form = [{symbol, <<"+">>}, 1, 2],
    Res = (catch apply('Elixir.BeamLisp.Ns.Bootstrap.Nano', run, [Form])),
    io:format("bare-erl (+ 1 2) => ~p~n", [Res]),
    case Res of 3 -> io:format("P0-BARE PASS~n"); _ -> io:format("P0-BARE FAIL~n") end,
    halt(0).
