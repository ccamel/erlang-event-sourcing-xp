-module(event_sourcing_store_mnesia_tests).

-include_lib("eunit/include/eunit.hrl").

%%% Internal helpers

-define(STORE, event_sourcing_store_mnesia).

setup() ->
    mnesia:start().

teardown() ->
    mnesia:stop().

%%% Test cases

create_table_once_test() ->
    setup(),

    ?assertMatch({ok, _}, event_sourcing_store:start(?STORE)),

    teardown().

create_table_multiple_times_test() ->
    setup(),

    ?assertMatch({ok, _}, event_sourcing_store:start(?STORE)),
    ?assertMatch({ok, _}, event_sourcing_store:start(?STORE)),

    teardown().

persist_single_event_test() ->
    setup(),
    ?assertMatch({ok, _}, event_sourcing_store:start(?STORE)),
    Timestamp = calendar:universal_time(),
    Event =
        event_sourcing_store:new_event(stream_A,
                                       user,
                                       user_registered,
                                       1,
                                       Timestamp,
                                       {"John Doe"}),

    ?assertMatch(ok, event_sourcing_store:persist_events(?STORE, stream_A, [Event])),
    ?assertMatch({ok, [Event]}, event_sourcing_store:retrieve_events(?STORE, stream_A, [])),

    teardown().

persist_2_streams_event_test() ->
    setup(),
    ?assertMatch({ok, _}, event_sourcing_store:start(?STORE)),
    Timestamp = calendar:universal_time(),

    EventStreamA =
        [event_sourcing_store:new_event(stream_A,
                                        user,
                                        user_registered,
                                        1,
                                        Timestamp,
                                        {"John Doe"})],
    EventStreamB =
        [event_sourcing_store:new_event(stream_B,
                                        user,
                                        user_registered,
                                        1,
                                        Timestamp,
                                        {"Jane Doe"})],

    ?assertMatch(ok, event_sourcing_store:persist_events(?STORE, stream_A, EventStreamA)),
    ?assertMatch(ok, event_sourcing_store:persist_events(?STORE, stream_B, EventStreamB)),

    ?assertMatch({ok, EventStreamA},
                 event_sourcing_store:retrieve_events(?STORE, stream_A, [])),
    ?assertMatch({ok, EventStreamB},
                 event_sourcing_store:retrieve_events(?STORE, stream_B, [])),

    teardown().

fetch_streams_event_test() ->
    setup(),
    ?assertMatch({ok, _}, ?STORE:start()),
    Timestamp = calendar:universal_time(),
    Events =
        [event_sourcing_store:new_event(stream_A,
                                        user,
                                        user_registered,
                                        1,
                                        Timestamp,
                                        {"Jon Doe"}),
         event_sourcing_store:new_event(stream_A, user, user_updated, 2, Timestamp, {"John Doe"}),
         event_sourcing_store:new_event(stream_A, user, user_deleted, 3, Timestamp, {})],

    ?assertMatch(ok, event_sourcing_store:persist_events(?STORE, stream_A, Events)),
    ?assertMatch({ok, []}, event_sourcing_store:retrieve_events(?STORE, stream_X, [])),
    ?assertMatch({ok, []},
                 event_sourcing_store:retrieve_events(?STORE, stream_A, [{from, 0}, {to, 1}])),
    ?assertMatch({ok, []},
                 event_sourcing_store:retrieve_events(?STORE, stream_A, [{from, 1}, {to, 1}])),

    Event1 = lists:nth(1, Events),
    Event2 = lists:nth(2, Events),
    Event3 = lists:nth(3, Events),
    ?assertMatch({ok, [Event1]},
                 event_sourcing_store:retrieve_events(?STORE, stream_A, [{from, 1}, {to, 2}])),
    ?assertMatch({ok, [Event2]},
                 event_sourcing_store:retrieve_events(?STORE, stream_A, [{from, 2}, {to, 3}])),
    ?assertMatch({ok, [Event2, Event3]},
                 event_sourcing_store:retrieve_events(?STORE, stream_A, [{from, 2}, {to, 4}])),
    ?assertMatch({ok, [Event2]},
                 event_sourcing_store:retrieve_events(?STORE,
                                                      stream_A,
                                                      [{from, 2}, {to, 4}, {limit, 1}])),
    ?assertMatch({ok, Events}, event_sourcing_store:retrieve_events(?STORE, stream_A, [])),

    teardown().

wrong_stream_id_test() ->
    setup(),
    ?assertMatch({ok, _}, ?STORE:start()),
    Timestamp = calendar:universal_time(),
    Event =
        event_sourcing_store:new_event(stream_A,
                                       user,
                                       user_registered,
                                       1,
                                       Timestamp,
                                       {"John Doe"}),

    ?assertMatch({error, {wrong_stream_id, {expected, stream_B, got, stream_A}}},
                 event_sourcing_store:persist_events(?STORE, stream_B, [Event])),
    ?assertMatch({ok, []}, event_sourcing_store:retrieve_events(?STORE, stream_A, [])),
    ?assertMatch({ok, []}, event_sourcing_store:retrieve_events(?STORE, stream_B, [])),

    teardown().

duplicate_event_test() ->
    setup(),
    ?assertMatch({ok, _}, ?STORE:start()),
    Timestamp = calendar:universal_time(),
    Event =
        event_sourcing_store:new_event(stream_A,
                                       user,
                                       user_registered,
                                       1,
                                       Timestamp,
                                       {"John Doe"}),

    ?assertMatch(ok, event_sourcing_store:persist_events(?STORE, stream_A, [Event])),
    ?assertMatch({error, {duplicate_event, {event_id, {user, stream_A, 1}}}},
                 event_sourcing_store:persist_events(?STORE, stream_A, [Event])),
    ?assertMatch({ok, [Event]}, event_sourcing_store:retrieve_events(?STORE, stream_A, [])),
    Events =
        [event_sourcing_store:new_event(stream_B,
                                        user,
                                        user_registered,
                                        1,
                                        Timestamp,
                                        {"Jon Doe"}),
         event_sourcing_store:new_event(stream_B, user, user_updated, 2, Timestamp, {"John Doe"}),
         event_sourcing_store:new_event(stream_B,
                                        user,
                                        user_registered,
                                        1,
                                        Timestamp,
                                        {"Jon Doe"})],

    ?assertMatch({error, {duplicate_event, {event_id, {user, stream_B, 1}}}},
                 event_sourcing_store:persist_events(?STORE, stream_B, Events)),
    ?assertMatch({ok, []}, event_sourcing_store:retrieve_events(?STORE, stream_B, [])),

    teardown().
