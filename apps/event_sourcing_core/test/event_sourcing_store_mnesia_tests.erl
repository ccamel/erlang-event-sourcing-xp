-module(event_sourcing_store_mnesia_tests).

-include_lib("eunit/include/eunit.hrl").

suite_test_() ->
    Stores = [event_sourcing_store_mnesia],
    BaseTests =
        [{"create_table_once", fun create_table_once/1},
         {"create_table_multiple_times", fun create_table_multiple_times/1},
         {"persist_single_event", fun persist_single_event/1},
         {"persist_2_streams_event", fun persist_2_streams_event/1},
         {"fetch_streams_event", fun fetch_streams_event/1},
         {"wrong_stream_id", fun wrong_stream_id/1},
         {"duplicate_event", fun duplicate_event/1}],
    TestCases =
        [{TestName ++ "__" ++ atom_to_list(Param), fun() -> TestFun(Param) end}
         || Param <- Stores, {TestName, TestFun} <- BaseTests],
    {foreach, fun setup/0, fun teardown/1, TestCases}.

setup() ->
    mnesia:start(),
    ok.

teardown(_) ->
    mnesia:stop(),
    ok.

%%% Test cases

create_table_once(Store) ->
    ?assertMatch({ok, _}, event_sourcing_store:start(Store)).

create_table_multiple_times(Store) ->
    ?assertMatch({ok, _}, event_sourcing_store:start(Store)),
    ?assertMatch({ok, _}, event_sourcing_store:start(Store)).

persist_single_event(Store) ->
    ?assertMatch({ok, _}, event_sourcing_store:start(Store)),
    Timestamp = calendar:universal_time(),
    Event =
        event_sourcing_store:new_event(stream_A,
                                       user,
                                       user_registered,
                                       1,
                                       Timestamp,
                                       {"John Doe"}),

    ?assertMatch(ok, event_sourcing_store:persist_events(Store, stream_A, [Event])),
    ?assertMatch({ok, [Event]}, event_sourcing_store:retrieve_events(Store, stream_A, [])),
    ?assertEqual({ok}, event_sourcing_store:stop(Store)).

persist_2_streams_event(Store) ->
    ?assertMatch({ok, _}, event_sourcing_store:start(Store)),
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

    ?assertMatch(ok, event_sourcing_store:persist_events(Store, stream_A, EventStreamA)),
    ?assertMatch(ok, event_sourcing_store:persist_events(Store, stream_B, EventStreamB)),

    ?assertMatch({ok, EventStreamA},
                 event_sourcing_store:retrieve_events(Store, stream_A, [])),
    ?assertMatch({ok, EventStreamB},
                 event_sourcing_store:retrieve_events(Store, stream_B, [])),
    ?assertEqual({ok}, event_sourcing_store:stop(Store)).

fetch_streams_event(Store) ->
    ?assertMatch({ok, _}, event_sourcing_store:start(Store)),
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

    ?assertMatch(ok, event_sourcing_store:persist_events(Store, stream_A, Events)),
    ?assertMatch({ok, []}, event_sourcing_store:retrieve_events(Store, stream_X, [])),
    ?assertMatch({ok, []},
                 event_sourcing_store:retrieve_events(Store, stream_A, [{from, 0}, {to, 1}])),
    ?assertMatch({ok, []},
                 event_sourcing_store:retrieve_events(Store, stream_A, [{from, 1}, {to, 1}])),

    Event1 = lists:nth(1, Events),
    Event2 = lists:nth(2, Events),
    Event3 = lists:nth(3, Events),
    ?assertMatch({ok, [Event1]},
                 event_sourcing_store:retrieve_events(Store, stream_A, [{from, 1}, {to, 2}])),
    ?assertMatch({ok, [Event2]},
                 event_sourcing_store:retrieve_events(Store, stream_A, [{from, 2}, {to, 3}])),
    ?assertMatch({ok, [Event2, Event3]},
                 event_sourcing_store:retrieve_events(Store, stream_A, [{from, 2}, {to, 4}])),
    ?assertMatch({ok, [Event2]},
                 event_sourcing_store:retrieve_events(Store,
                                                      stream_A,
                                                      [{from, 2}, {to, 4}, {limit, 1}])),
    ?assertMatch({ok, Events}, event_sourcing_store:retrieve_events(Store, stream_A, [])),
    ?assertEqual({ok}, Store:stop()).

wrong_stream_id(Store) ->
    ?assertMatch({ok, _}, event_sourcing_store:start(Store)),
    Timestamp = calendar:universal_time(),
    Event =
        event_sourcing_store:new_event(stream_A,
                                       user,
                                       user_registered,
                                       1,
                                       Timestamp,
                                       {"John Doe"}),

    ?assertMatch({error, {wrong_stream_id, {expected, stream_B, got, stream_A}}},
                 event_sourcing_store:persist_events(Store, stream_B, [Event])),
    ?assertMatch({ok, []}, event_sourcing_store:retrieve_events(Store, stream_A, [])),
    ?assertMatch({ok, []}, event_sourcing_store:retrieve_events(Store, stream_B, [])),
    ?assertEqual({ok}, Store:stop()).

duplicate_event(Store) ->
    ?assertMatch({ok, _}, event_sourcing_store:start(Store)),
    Timestamp = calendar:universal_time(),
    Event =
        event_sourcing_store:new_event(stream_A,
                                       user,
                                       user_registered,
                                       1,
                                       Timestamp,
                                       {"John Doe"}),

    ?assertMatch(ok, event_sourcing_store:persist_events(Store, stream_A, [Event])),
    ?assertMatch({error, {duplicate_event, {event_id, {user, stream_A, 1}}}},
                 event_sourcing_store:persist_events(Store, stream_A, [Event])),
    ?assertMatch({ok, [Event]}, event_sourcing_store:retrieve_events(Store, stream_A, [])),
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
                 event_sourcing_store:persist_events(Store, stream_B, Events)),
    ?assertMatch({ok, []}, event_sourcing_store:retrieve_events(Store, stream_B, [])),
    ?assertEqual({ok}, Store:stop()).
