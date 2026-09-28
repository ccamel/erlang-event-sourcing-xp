-module(es_store_postgres_tests).

-include_lib("eunit/include/eunit.hrl").

postgres_store_test_() ->
    case os:getenv("ES_POSTGRES_TEST") of
        "true" ->
            {setup, fun setup/0, fun teardown/1, fun store_contract/1};
        _ ->
            []
    end.

setup() ->
    configure_store(),
    {ok, _Started} = application:ensure_all_started(es_store_postgres),
    UniqueId = integer_to_binary(erlang:unique_integer([positive])),
    {postgres_store_test, UniqueId}.

teardown(_StreamId) ->
    ok = application:stop(es_store_postgres),
    unset_store_configuration().

store_contract(StreamId) ->
    Event0 = event(StreamId, 0, created),
    Event1 = event(StreamId, 1, updated),
    Snapshot0 = es_kernel_store:new_snapshot(postgres_store_test, StreamId, 0, 1, #{value => 0}),
    Snapshot1 = es_kernel_store:new_snapshot(postgres_store_test, StreamId, 1, 2, #{value => 1}),
    [
        ?_assertEqual(ok, es_store_postgres:append(StreamId, [Event0])),
        ?_assertEqual(
            {error, duplicate_event}, es_store_postgres:append(StreamId, [Event1, Event0])
        ),
        ?_assertEqual({ok, [created]}, event_types(StreamId)),
        ?_assertEqual(ok, es_store_postgres:append(StreamId, [Event1])),
        ?_assertEqual({ok, [created, updated]}, event_types(StreamId)),
        ?_assert(positions_are_increasing(StreamId)),
        ?_assertEqual(ok, es_store_postgres:store(Snapshot0)),
        ?_assertEqual(ok, es_store_postgres:store(Snapshot1)),
        ?_assertEqual({ok, Snapshot1}, es_store_postgres:load_latest(StreamId))
    ].

configure_store() ->
    application:set_env(es_store_postgres, host, env("ES_POSTGRES_TEST_HOST", "127.0.0.1")),
    application:set_env(es_store_postgres, port, env_port("ES_POSTGRES_TEST_PORT", 5432)),
    application:set_env(es_store_postgres, database, env("ES_POSTGRES_TEST_DATABASE", "es_xp")),
    application:set_env(es_store_postgres, username, env("ES_POSTGRES_TEST_USERNAME", "es_xp")),
    application:set_env(es_store_postgres, password, env("ES_POSTGRES_TEST_PASSWORD", "es_xp")).

unset_store_configuration() ->
    lists:foreach(
        fun(Key) -> application:unset_env(es_store_postgres, Key) end,
        [host, port, database, username, password]
    ).

env(Key, Default) ->
    case os:getenv(Key) of
        false -> Default;
        Value -> Value
    end.

env_port(Key, Default) ->
    case os:getenv(Key) of
        false -> Default;
        Value -> list_to_integer(Value)
    end.

event(StreamId, Sequence, Type) ->
    es_kernel_store:new_event(StreamId, postgres_store_test, Type, Sequence, Sequence, #{}).

event_types(StreamId) ->
    case
        es_store_postgres:fold(
            StreamId,
            fun(#{type := Type}, _Sequence, Types) -> [Type | Types] end,
            [],
            es_contract_range:new(0, infinity)
        )
    of
        {ok, Types} ->
            {ok, lists:reverse(Types)};
        {error, _Reason} = Error ->
            Error
    end.

positions_are_increasing(StreamId) ->
    case
        es_store_postgres:fold_all(
            fun
                (#{stream_id := EventStreamId}, Position, Positions) when
                    EventStreamId =:= StreamId
                ->
                    [Position | Positions];
                (_Event, _Position, Positions) ->
                    Positions
            end,
            [],
            es_contract_range:new(0, infinity)
        )
    of
        {ok, [LaterPosition, EarlierPosition]} ->
            EarlierPosition < LaterPosition;
        _ ->
            false
    end.
