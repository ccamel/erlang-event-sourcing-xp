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
    UniqueId = iolist_to_binary([
        integer_to_binary(erlang:system_time(microsecond)),
        $-,
        integer_to_binary(erlang:unique_integer([positive]))
    ]),
    {postgres_store_test, UniqueId}.

teardown(_StreamId) ->
    ok = application:stop(es_store_postgres),
    unset_store_configuration().

store_contract(StreamId) ->
    Event0 = event(StreamId, 0, created),
    Event1 = event(StreamId, 1, updated),
    Event2 = event(StreamId, 2, <<"archived">>),
    Snapshot0 = es_kernel_store:new_snapshot(postgres_store_test, StreamId, 0, 1, #{value => 0}),
    Snapshot1 = es_kernel_store:new_snapshot(postgres_store_test, StreamId, 1, 2, #{value => 1}),
    [
        ?_assertEqual(ok, es_store_postgres:start()),
        ?_assertEqual(ok, es_store_postgres:append(StreamId, [])),
        ?_assertEqual(ok, es_store_postgres:append(StreamId, [Event0])),
        ?_assertEqual(
            {ok, {<<"postgres_store_test">>, <<"created">>, 0}},
            indexed_event_fields(StreamId)
        ),
        ?_assertEqual(
            {error, duplicate_event}, es_store_postgres:append(StreamId, [Event1, Event0])
        ),
        ?_assertEqual({ok, [created]}, event_types(StreamId)),
        ?_assertEqual(ok, es_store_postgres:append(StreamId, [Event1])),
        ?_assertEqual({ok, [updated]}, event_types(StreamId, es_contract_range:new(1, 2))),
        ?_assertEqual({ok, [created, updated]}, event_types(StreamId)),
        ?_assert(positions_are_increasing(StreamId)),
        ?_assert(global_range_is_bounded(StreamId)),
        ?_assertEqual(
            {error, {error, stream_callback_failed}},
            es_store_postgres:fold(
                StreamId,
                fun(_Event, _Sequence, _Acc) -> error(stream_callback_failed) end,
                [],
                es_contract_range:new(0, infinity)
            )
        ),
        ?_assertEqual(
            {error, {error, global_callback_failed}},
            es_store_postgres:fold_all(
                fun(_Event, _Position, _Acc) -> error(global_callback_failed) end,
                [],
                es_contract_range:new(0, infinity)
            )
        ),
        ?_assertEqual(ok, es_store_postgres:append(StreamId, [Event2])),
        ?_assertEqual({ok, [created, updated, <<"archived">>]}, event_types(StreamId)),
        ?_assertEqual({error, not_found}, es_store_postgres:load_latest({missing, StreamId})),
        ?_assertEqual(ok, es_store_postgres:store(Snapshot0)),
        ?_assertEqual(ok, es_store_postgres:store(Snapshot1)),
        ?_assertEqual(ok, es_store_postgres:store(Snapshot0)),
        ?_assertEqual({ok, Snapshot1}, es_store_postgres:load_latest(StreamId))
    ].

configure_store() ->
    application:set_env(
        es_store_postgres,
        host,
        unicode:characters_to_binary(env("ES_POSTGRES_TEST_HOST", "127.0.0.1"))
    ),
    application:set_env(
        es_store_postgres, port, integer_to_list(env_port("ES_POSTGRES_TEST_PORT", 5432))
    ),
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

test_connection_options() ->
    [
        {host, env("ES_POSTGRES_TEST_HOST", "127.0.0.1")},
        {port, env_port("ES_POSTGRES_TEST_PORT", 5432)},
        {database, env("ES_POSTGRES_TEST_DATABASE", "es_xp")},
        {username, env("ES_POSTGRES_TEST_USERNAME", "es_xp")},
        {password, env("ES_POSTGRES_TEST_PASSWORD", "es_xp")}
    ].

event(StreamId, Sequence, Type) ->
    es_kernel_store:new_event(StreamId, postgres_store_test, Type, Sequence, Sequence, #{}).

indexed_event_fields(StreamId) ->
    {ok, Connection} = epgsql:connect(test_connection_options()),
    try
        case
            epgsql:equery(
                Connection,
                "SELECT aggregate_type, event_type, occurred_at FROM es_events WHERE stream_id = $1",
                [term_to_binary(StreamId, [compressed])]
            )
        of
            {ok, _Columns, [Fields]} ->
                {ok, Fields};
            {ok, _Columns, []} ->
                {error, not_found};
            {error, Reason} ->
                {error, Reason}
        end
    after
        ok = epgsql:close(Connection)
    end.

event_types(StreamId) ->
    event_types(StreamId, es_contract_range:new(0, infinity)).

event_types(StreamId, Range) ->
    case
        es_store_postgres:fold(
            StreamId,
            fun(#{type := Type}, _Sequence, Types) -> [Type | Types] end,
            [],
            Range
        )
    of
        {ok, Types} ->
            {ok, lists:reverse(Types)};
        {error, _Reason} = Error ->
            Error
    end.

positions_are_increasing(StreamId) ->
    case stream_positions(StreamId) of
        {ok, [LaterPosition, EarlierPosition]} ->
            EarlierPosition < LaterPosition;
        _ ->
            false
    end.

global_range_is_bounded(StreamId) ->
    case stream_positions(StreamId) of
        {ok, [LaterPosition, EarlierPosition]} ->
            case
                global_event_types(
                    StreamId, es_contract_range:new(EarlierPosition, LaterPosition)
                )
            of
                {ok, [created]} ->
                    true;
                _ ->
                    false
            end;
        _ ->
            false
    end.

stream_positions(StreamId) ->
    es_store_postgres:fold_all(
        fun
            (#{stream_id := EventStreamId}, Position, Positions) when EventStreamId =:= StreamId ->
                [Position | Positions];
            (_Event, _Position, Positions) ->
                Positions
        end,
        [],
        es_contract_range:new(0, infinity)
    ).

global_event_types(StreamId, Range) ->
    case
        es_store_postgres:fold_all(
            fun
                (#{stream_id := EventStreamId, type := Type}, _Position, Types) when
                    EventStreamId =:= StreamId
                ->
                    [Type | Types];
                (_Event, _Position, Types) ->
                    Types
            end,
            [],
            Range
        )
    of
        {ok, Types} ->
            {ok, lists:reverse(Types)};
        {error, _Reason} = Error ->
            Error
    end.
