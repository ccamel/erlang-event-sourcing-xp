-module(es_store_file_app).
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _Args) ->
    case es_store_file:start() of
        ok ->
            es_store_file_sup:start_link();
        {error, _} = Error ->
            Error
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    ok = es_store_file:stop(),
    ok.
