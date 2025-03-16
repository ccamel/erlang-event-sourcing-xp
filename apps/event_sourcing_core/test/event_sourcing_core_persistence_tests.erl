-module(event_sourcing_core_persistence_tests).

-include_lib("eunit/include/eunit.hrl").

%%% Internal helpers

setup() ->
    mnesia:start().

teardown() ->
    mnesia:stop().

table_count(Table) ->
    {atomic, Count} = mnesia:transaction(fun() -> mnesia:table_info(Table, size) end),
    Count.

is_table_empty(Table) ->
    0 == table_count(Table).

retrieve_events(StreamId, Options) ->
    case event_sourcing_core_persistence:retrieve_and_fold_events(StreamId,
                                                                  Options,
                                                                  fun(Payload, Acc) ->
                                                                     [Payload | Acc]
                                                                  end,
                                                                  [])
    of
        {ok, ReversedEvents} ->
            {ok, lists:reverse(ReversedEvents)};
        Error ->
            Error
    end.

retrieve_events(StreamId) ->
    retrieve_events(StreamId, []).

%%% Test cases

create_table_once_test() ->
    setup(),

    ok = event_sourcing_core_persistence:create_events_table(),

    ?assertNotEqual(undefined,
                    mnesia:table_info(
                        event_sourcing_core_persistence:table_name(events), all)),
    ?assertEqual(true, is_table_empty(event_sourcing_core_persistence:table_name(events))),

    teardown().

create_table_multiple_times_test() ->
    setup(),

    ?assertMatch(ok, event_sourcing_core_persistence:create_events_table()),
    ?assertMatch(ok, event_sourcing_core_persistence:create_events_table()),

    ?assertNotEqual(undefined,
                    mnesia:table_info(
                        event_sourcing_core_persistence:table_name(events), all)),
    ?assertEqual(true, is_table_empty(event_sourcing_core_persistence:table_name(events))),

    teardown().

persist_single_event_test() ->
    setup(),
    event_sourcing_core_persistence:create_events_table(),

    StreamId = "stream_A",
    Payload = {user_registered, "John Doe"},
    Version = 1,

    {ok, EventId} = event_sourcing_core_persistence:persist_event(StreamId, Version, Payload),
    ?assertEqual(1, table_count(event_sourcing_core_persistence:table_name(events))),
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
                 retrieve_events(StreamId)),

    teardown().

persist_2_streams_event_test() ->
    setup(),
    event_sourcing_core_persistence:create_events_table(),

    StreamIdA = "stream_A",
    PayloadA = {user_registered, "John Doe"},
    VersionA = 1,
    {ok, EventIdA} =
        event_sourcing_core_persistence:persist_event(StreamIdA, VersionA, PayloadA),
    ?assertEqual(1, table_count(event_sourcing_core_persistence:table_name(events))),

    StreamIdB = "stream_B",
    PayloadB = {user_registered, "Jane Doe"},
    VersionB = 1,
    {ok, EventIdB} =
        event_sourcing_core_persistence:persist_event(StreamIdB, VersionB, PayloadB),
    ?assertEqual(2, table_count(event_sourcing_core_persistence:table_name(events))),

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
                 retrieve_events(StreamIdA)),
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
                 retrieve_events(StreamIdB)),

    teardown().

fetch_streams_event_test() ->
    setup(),
    event_sourcing_core_persistence:create_events_table(),

    StreamId = "stream_A",

    Payload1 = {user_registered, "Jon Doe"},
    Version1 = 1,
    {ok, EventId1} =
        event_sourcing_core_persistence:persist_event(StreamId, Version1, Payload1),

    Payload2 = {user_updated, "John Doe"},
    Version2 = 2,
    {ok, EventId2} =
        event_sourcing_core_persistence:persist_event(StreamId, Version2, Payload2),

    Payload3 = {user_deleted},
    Version3 = 3,
    {ok, EventId3} =
        event_sourcing_core_persistence:persist_event(StreamId, Version3, Payload3),

    ?assertMatch({ok, []}, retrieve_events(StreamId, [{from, 0}, {to, 1}])),
    ?assertMatch({ok, []}, retrieve_events(StreamId, [{from, 1}, {to, 1}])),
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
                 retrieve_events(StreamId, [{from, 1}, {to, 2}])),
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
                 retrieve_events(StreamId, [{from, 2}, {to, 3}])),

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
                 retrieve_events(StreamId, [{from, 2}, {to, 4}])),

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
                 retrieve_events(StreamId)),

    teardown().
