-module(event_sourcing_core_store_tests).

-include_lib("eunit/include/eunit.hrl").

suite_test_() ->
    Stores = [event_sourcing_core_store_mnesia, event_sourcing_core_store_ets],
    BaseTests =
        [
            {"start_once", fun start_once/1},
            {"start_multiple_times", fun start_multiple_times/1},
            {"persist_single_event", fun persist_single_event/1},
            {"persist_2_streams_event", fun persist_2_streams_event/1},
            {"fetch_streams_event", fun fetch_streams_event/1},
            {"wrong_stream_id", fun wrong_stream_id/1},
            {"duplicate_event", fun duplicate_event/1}
        ],
    TestCases =
        [
            {TestName ++ "__" ++ atom_to_list(Param), fun() -> TestFun(Param) end}
         || Param <- Stores, {TestName, TestFun} <- BaseTests
        ],
    {foreach, fun setup/0, fun teardown/1, TestCases}.

setup() ->
    mnesia:start(),
    ok.

teardown(_) ->
    mnesia:stop(),
    ok.

%%% Test cases

start_once(Store) ->
    ?assertMatch(ok, event_sourcing_core_store:start(Store)).

start_multiple_times(Store) ->
    ?assertMatch(ok, event_sourcing_core_store:start(Store)),
    ?assertMatch(ok, event_sourcing_core_store:start(Store)).

persist_single_event(Store) ->
    ?assertMatch(ok, event_sourcing_core_store:start(Store)),
    Timestamp = erlang:system_time(),
    Event =
        event_sourcing_core_store:new_event(
            stream_A,
            user,
            user_registered,
            1,
            Timestamp,
            {"John Doe"}
        ),

    ?assertMatch(ok, event_sourcing_core_store:persist_events(Store, stream_A, [Event])),
    ?assertMatch([Event], event_sourcing_core_store:retrieve_events(Store, stream_A, #{})),
    ?assertEqual(ok, event_sourcing_core_store:stop(Store)).

persist_2_streams_event(Store) ->
    ?assertMatch(ok, event_sourcing_core_store:start(Store)),
    Timestamp = erlang:system_time(),

    EventStreamA =
        [
            event_sourcing_core_store:new_event(
                stream_A,
                user,
                user_registered,
                1,
                Timestamp,
                {"John Doe"}
            )
        ],
    EventStreamB =
        [
            event_sourcing_core_store:new_event(
                stream_B,
                user,
                user_registered,
                1,
                Timestamp,
                {"Jane Doe"}
            )
        ],

    ?assertMatch(ok, event_sourcing_core_store:persist_events(Store, stream_A, EventStreamA)),
    ?assertMatch(ok, event_sourcing_core_store:persist_events(Store, stream_B, EventStreamB)),

    ?assertMatch(
        EventStreamA,
        event_sourcing_core_store:retrieve_events(Store, stream_A, #{})
    ),
    ?assertMatch(
        EventStreamB,
        event_sourcing_core_store:retrieve_events(Store, stream_B, #{})
    ),
    ?assertEqual(ok, event_sourcing_core_store:stop(Store)).

fetch_streams_event(Store) ->
    ?assertMatch(ok, event_sourcing_core_store:start(Store)),
    Timestamp = erlang:system_time(),
    Events =
        [
            event_sourcing_core_store:new_event(
                stream_A,
                user,
                user_registered,
                1,
                Timestamp,
                {"Jon Doe"}
            ),
            event_sourcing_core_store:new_event(
                stream_A,
                user,
                user_updated,
                2,
                Timestamp,
                {"John Doe"}
            ),
            event_sourcing_core_store:new_event(stream_A, user, user_deleted, 3, Timestamp, {})
        ],

    ?assertMatch(ok, event_sourcing_core_store:persist_events(Store, stream_A, Events)),
    ?assertMatch([], event_sourcing_core_store:retrieve_events(Store, stream_X, #{})),
    ?assertMatch(
        [],
        event_sourcing_core_store:retrieve_events(Store, stream_A, #{from => 0, to => 1})
    ),
    ?assertMatch(
        [],
        event_sourcing_core_store:retrieve_events(Store, stream_A, #{from => 1, to => 1})
    ),

    Event1 = lists:nth(1, Events),
    Event2 = lists:nth(2, Events),
    Event3 = lists:nth(3, Events),
    ?assertMatch(
        [Event1],
        event_sourcing_core_store:retrieve_events(Store, stream_A, #{from => 1, to => 2})
    ),
    ?assertMatch(
        [Event2],
        event_sourcing_core_store:retrieve_events(Store, stream_A, #{from => 2, to => 3})
    ),
    ?assertMatch(
        [Event2, Event3],
        event_sourcing_core_store:retrieve_events(Store, stream_A, #{from => 2, to => 4})
    ),
    ?assertMatch(
        [Event2],
        event_sourcing_core_store:retrieve_events(
            Store,
            stream_A,
            #{
                from => 2,
                to => 4,
                limit => 1
            }
        )
    ),
    ?assertMatch(Events, event_sourcing_core_store:retrieve_events(Store, stream_A, #{})),
    ?assertEqual(ok, Store:stop()).

wrong_stream_id(Store) ->
    ?assertMatch(ok, event_sourcing_core_store:start(Store)),
    Timestamp = erlang:system_time(),
    Event =
        event_sourcing_core_store:new_event(
            stream_A,
            user,
            user_registered,
            1,
            Timestamp,
            {"John Doe"}
        ),

    ?assertException(
        error,
        {badarg, stream_A},
        event_sourcing_core_store:persist_events(Store, stream_B, [Event])
    ),
    ?assertMatch([], event_sourcing_core_store:retrieve_events(Store, stream_A, #{})),
    ?assertMatch([], event_sourcing_core_store:retrieve_events(Store, stream_B, #{})),
    ?assertEqual(ok, Store:stop()).

duplicate_event(Store) ->
    ?assertMatch(ok, event_sourcing_core_store:start(Store)),
    Timestamp = erlang:system_time(),
    Event =
        event_sourcing_core_store:new_event(
            stream_A,
            user,
            user_registered,
            1,
            Timestamp,
            {"John Doe"}
        ),

    ?assertMatch(ok, event_sourcing_core_store:persist_events(Store, stream_A, [Event])),
    ?assertException(
        error,
        duplicate_event,
        event_sourcing_core_store:persist_events(Store, stream_A, [Event])
    ),
    ?assertMatch([Event], event_sourcing_core_store:retrieve_events(Store, stream_A, #{})),
    Events =
        [
            event_sourcing_core_store:new_event(
                stream_B,
                user,
                user_registered,
                1,
                Timestamp,
                {"Jon Doe"}
            ),
            event_sourcing_core_store:new_event(
                stream_B,
                user,
                user_updated,
                2,
                Timestamp,
                {"John Doe"}
            ),
            event_sourcing_core_store:new_event(
                stream_B,
                user,
                user_registered,
                1,
                Timestamp,
                {"Jon Doe"}
            )
        ],

    ?assertException(
        error,
        duplicate_event,
        event_sourcing_core_store:persist_events(Store, stream_B, Events)
    ),
    ?assertMatch([], event_sourcing_core_store:retrieve_events(Store, stream_B, #{})),
    ?assertEqual(ok, Store:stop()).
