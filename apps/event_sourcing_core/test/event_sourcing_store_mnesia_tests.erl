-module(event_sourcing_store_mnesia_tests).

-include_lib("eunit/include/eunit.hrl").

%%% Internal helpers

-define(STORE, event_sourcing_store_mnesia).

setup() ->
    mnesia:start().

teardown() ->
    mnesia:stop().

table_count(Table) ->
    {atomic, Count} = mnesia:transaction(fun() -> mnesia:table_info(Table, size) end),
    Count.

is_table_empty(Table) ->
    0 == table_count(Table).

%%% Test cases

create_table_once_test() ->
    setup(),

    ?assertMatch({ok, _}, event_sourcing_store:start(?STORE)),

    ?assertNotEqual(undefined,
                    mnesia:table_info(
                        event_sourcing_store_mnesia:table_name(events), all)),
    ?assertEqual(true, is_table_empty(event_sourcing_store_mnesia:table_name(events))),

    teardown().

create_table_multiple_times_test() ->
    setup(),

    ?assertMatch({ok, _}, event_sourcing_store:start(?STORE)),
    ?assertMatch({ok, _}, event_sourcing_store:start(?STORE)),

    ?assertNotEqual(undefined,
                    mnesia:table_info(
                        ?STORE:table_name(events), all)),
    ?assertEqual(true, is_table_empty(?STORE:table_name(events))),

    teardown().

persist_single_event_test() ->
    setup(),
    ?assertMatch({ok, _}, event_sourcing_store:start(?STORE)),

    StreamId = "stream_A",
    Payload = {user_registered, "John Doe"},
    Version = 1,

    {ok, EventId} = event_sourcing_store:persist_event(?STORE, StreamId, Version, Payload),
    ?assertEqual(1, table_count(?STORE:table_name(events))),
    ?assertMatch({ok,
                  [{event_record,
                    EventId,
                    "user_registered",
                    "stream_A",
                    1,
                    [],
                    _,
                    #{},
                    {user_registered, "John Doe"}}]},
                 event_sourcing_store:retrieve_events(?STORE, StreamId, [])),

    teardown().

persist_2_streams_event_test() ->
    setup(),
    ?assertMatch({ok, _}, event_sourcing_store:start(?STORE)),

    StreamIdA = "stream_A",
    PayloadA = {user_registered, "John Doe"},
    VersionA = 1,
    {ok, EventIdA} =
        event_sourcing_store:persist_event(?STORE, StreamIdA, VersionA, PayloadA),
    ?assertEqual(1, table_count(?STORE:table_name(events))),

    StreamIdB = "stream_B",
    PayloadB = {user_registered, "Jane Doe"},
    VersionB = 1,
    {ok, EventIdB} =
        event_sourcing_store:persist_event(?STORE, StreamIdB, VersionB, PayloadB),
    ?assertEqual(2, table_count(?STORE:table_name(events))),

    ?assertMatch({ok,
                  [{event_record,
                    EventIdA,
                    "user_registered",
                    "stream_A",
                    1,
                    [],
                    _,
                    #{},
                    {user_registered, "John Doe"}}]},
                 event_sourcing_store:retrieve_events(?STORE, StreamIdA, [])),
    ?assertMatch({ok,
                  [{event_record,
                    EventIdB,
                    "user_registered",
                    "stream_B",
                    1,
                    [],
                    _,
                    #{},
                    {user_registered, "Jane Doe"}}]},
                 event_sourcing_store:retrieve_events(?STORE, StreamIdB, [])),

    teardown().

fetch_streams_event_test() ->
    setup(),
    ?assertMatch({ok, _}, ?STORE:start()),

    StreamId = "stream_A",

    Payload1 = {user_registered, "Jon Doe"},
    Version1 = 1,
    {ok, EventId1} = event_sourcing_store:persist_event(?STORE, StreamId, Version1, Payload1),

    Payload2 = {user_updated, "John Doe"},
    Version2 = 2,
    {ok, EventId2} = event_sourcing_store:persist_event(?STORE, StreamId, Version2, Payload2),

    Payload3 = {user_deleted},
    Version3 = 3,
    {ok, EventId3} = event_sourcing_store:persist_event(?STORE, StreamId, Version3, Payload3),

    ?assertMatch({ok, []},
                 event_sourcing_store:retrieve_events(?STORE, StreamId, [{from, 0}, {to, 1}])),
    ?assertMatch({ok, []},
                 event_sourcing_store:retrieve_events(?STORE, StreamId, [{from, 1}, {to, 1}])),
    ?assertMatch({ok,
                  [{event_record,
                    EventId1,
                    "user_registered",
                    "stream_A",
                    1,
                    [],
                    _,
                    #{},
                    {user_registered, "Jon Doe"}}]},
                 event_sourcing_store:retrieve_events(?STORE, StreamId, [{from, 1}, {to, 2}])),
    ?assertMatch({ok,
                  [{event_record,
                    EventId2,
                    "user_updated",
                    "stream_A",
                    2,
                    [],
                    _,
                    #{},
                    {user_updated, "John Doe"}}]},
                 event_sourcing_store:retrieve_events(?STORE, StreamId, [{from, 2}, {to, 3}])),

    ?assertMatch({ok,
                  [{event_record,
                    EventId2,
                    "user_updated",
                    "stream_A",
                    2,
                    [],
                    _,
                    #{},
                    {user_updated, "John Doe"}},
                   {event_record,
                    EventId3,
                    "user_deleted",
                    "stream_A",
                    3,
                    [],
                    _,
                    #{},
                    {user_deleted}}]},
                 event_sourcing_store:retrieve_events(?STORE, StreamId, [{from, 2}, {to, 4}])),

    ?assertMatch({ok,
                  [{event_record,
                    EventId1,
                    "user_registered",
                    "stream_A",
                    1,
                    [],
                    _,
                    #{},
                    {user_registered, "Jon Doe"}},
                   {event_record,
                    EventId2,
                    "user_updated",
                    "stream_A",
                    2,
                    [],
                    _,
                    #{},
                    {user_updated, "John Doe"}},
                   {event_record,
                    EventId3,
                    "user_deleted",
                    "stream_A",
                    3,
                    [],
                    _,
                    #{},
                    {user_deleted}}]},
                 event_sourcing_store:retrieve_events(?STORE, StreamId, [])),

    teardown().
