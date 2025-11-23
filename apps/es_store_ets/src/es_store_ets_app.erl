-module(es_store_ets_app).
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _Args) ->
    ok = es_store_ets:start(),
    es_store_ets_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok = es_store_ets:stop(),
    ok.
