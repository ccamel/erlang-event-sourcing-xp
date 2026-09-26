-module(es_xp_http_tests).

-include_lib("eunit/include/eunit.hrl").

http_api_test_() ->
    {setup, fun start/0, fun stop/1, fun http_api/1}.

start() ->
    ok = application:load(es_xp),
    ok = application:set_env(es_xp, http_port, 0),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(es_xp),
    ranch:get_port(es_xp_http_listener).

stop(_Port) ->
    _ = application:stop(inets),
    _ = application:stop(es_xp),
    _ = application:stop(es_projection),
    _ = application:stop(es_kernel),
    _ = application:stop(es_store_ets),
    _ = application:stop(cowboy),
    ok = application:unset_env(es_xp, http_port).

http_api(Port) ->
    [
        ?_assertEqual({200, #{<<"status">> => <<"ok">>}}, get(Port, "/healthz")),
        ?_assertEqual(
            {200, #{<<"ok">> => true}},
            post(Port, "/api/accounts/123/deposit", <<"{\"amount\":100}">>)
        ),
        ?_assertEqual(
            {200, #{<<"id">> => <<"123">>, <<"balance">> => 100}},
            get(Port, "/api/accounts/123")
        ),
        ?_assertEqual(
            {422, #{<<"error">> => <<"insufficient_funds">>}},
            post(Port, "/api/accounts/123/withdraw", <<"{\"amount\":101}">>)
        ),
        ?_assertEqual(
            {400, #{<<"error">> => <<"invalid_request">>}},
            post(Port, "/api/accounts/123/deposit", <<"{\"amount\":\"100\"}">>)
        )
    ].

get(Port, Path) ->
    {ok, {{_Version, Status, _Reason}, _Headers, Body}} = httpc:request(
        get, {url(Port, Path), []}, [], [{body_format, binary}]
    ),
    {Status, json:decode(Body)}.

post(Port, Path, Body) ->
    {ok, {{_Version, Status, _Reason}, _Headers, ResponseBody}} = httpc:request(
        post,
        {url(Port, Path), [], "application/json", Body},
        [],
        [{body_format, binary}]
    ),
    {Status, json:decode(ResponseBody)}.

url(Port, Path) ->
    lists:flatten(io_lib:format("http://127.0.0.1:~B~s", [Port, Path])).
