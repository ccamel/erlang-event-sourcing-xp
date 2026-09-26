-module(es_xp_http).
-moduledoc """
HTTP API for the event-sourcing example.
""".

-behaviour(cowboy_handler).
-behaviour(gen_server).

-export([
    start_link/0,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3,
    init/2
]).

-define(LISTENER, es_xp_http_listener).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

init([]) ->
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/healthz", ?MODULE, health},
            {"/api/accounts/:id", ?MODULE, account},
            {"/api/accounts/:id/deposit", ?MODULE, deposit},
            {"/api/accounts/:id/withdraw", ?MODULE, withdraw}
        ]}
    ]),
    case
        cowboy:start_clear(
            ?LISTENER,
            [{ip, {0, 0, 0, 0}}, {port, port()}],
            #{env => #{dispatch => Dispatch}}
        )
    of
        {ok, _Pid} ->
            {ok, #{}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    _ = cowboy:stop_listener(?LISTENER),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

init(Req0, Handler) ->
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            {ok, reply_options(Req0), Handler};
        <<"GET">> ->
            {ok, handle_get(Handler, Req0), Handler};
        <<"POST">> ->
            {ok, handle_post(Handler, Req0), Handler};
        _ ->
            {ok, reply_json(405, #{error => <<"method_not_allowed">>}, Req0), Handler}
    end.

handle_get(health, Req0) ->
    reply_json(200, #{status => <<"ok">>}, Req0);
handle_get(account, Req0) ->
    AccountId = cowboy_req:binding(id, Req0),
    case es_xp_account_query:balance(AccountId) of
        {ok, Balance} ->
            reply_json(200, #{id => AccountId, balance => Balance}, Req0);
        {error, _Reason} ->
            reply_json(500, #{error => <<"internal_error">>}, Req0)
    end;
handle_get(_, Req0) ->
    reply_json(405, #{error => <<"method_not_allowed">>}, Req0).

handle_post(Action, Req0) when Action =:= deposit; Action =:= withdraw ->
    AccountId = cowboy_req:binding(id, Req0),
    case read_amount(Req0) of
        {ok, Amount, Req1} ->
            Command = es_contract_command:new(
                bank_account, Action, AccountId, 0, #{}, #{amount => Amount}
            ),
            reply_dispatch(es_kernel:dispatch(Command), Req1);
        {error, Req1} ->
            reply_json(400, #{error => <<"invalid_request">>}, Req1)
    end;
handle_post(_, Req0) ->
    reply_json(405, #{error => <<"method_not_allowed">>}, Req0).

read_amount(Req0) ->
    case cowboy_req:read_body(Req0) of
        {ok, Body, Req1} ->
            try json:decode(Body) of
                #{<<"amount">> := Amount} when is_integer(Amount) ->
                    {ok, Amount, Req1};
                _ ->
                    {error, Req1}
            catch
                _:_ ->
                    {error, Req1}
            end;
        {more, _Body, Req1} ->
            {error, Req1}
    end.

reply_dispatch(ok, Req0) ->
    reply_json(200, #{ok => true}, Req0);
reply_dispatch({error, insufficient_funds}, Req0) ->
    reply_json(422, #{error => <<"insufficient_funds">>}, Req0);
reply_dispatch({error, invalid_command}, Req0) ->
    reply_json(400, #{error => <<"invalid_command">>}, Req0);
reply_dispatch({error, _Reason}, Req0) ->
    reply_json(500, #{error => <<"internal_error">>}, Req0).

reply_options(Req0) ->
    cowboy_req:reply(204, cors_headers(), Req0).

reply_json(Status, Body, Req0) ->
    Headers0 = cors_headers(),
    Headers = Headers0#{<<"content-type">> => <<"application/json">>},
    cowboy_req:reply(Status, Headers, json:encode(Body), Req0).

cors_headers() ->
    #{
        <<"access-control-allow-origin">> => <<"*">>,
        <<"access-control-allow-headers">> => <<"content-type">>,
        <<"access-control-allow-methods">> => <<"GET, POST, OPTIONS">>
    }.

port() ->
    case os:getenv("PORT") of
        false ->
            application:get_env(es_xp, http_port, 8080);
        Value ->
            parse_port(Value)
    end.

parse_port(Value) ->
    case string:to_integer(Value) of
        {Port, []} when Port >= 0, Port =< 65535 ->
            Port;
        _ ->
            error({invalid_http_port, Value})
    end.
