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
    Timestamp = calendar:universal_time(),
    Event =
        event_sourcing_store:new_event(stream_A,
                                       user,
                                       user_registered,
                                       1,
                                       Timestamp,
                                       {"John Doe"}),

    ?assertMatch(ok, event_sourcing_store:persist_event(?STORE, Event)),
    ?assertEqual(1, table_count(?STORE:table_name(events))),
    ?assertMatch({ok, [Event]}, event_sourcing_store:retrieve_events(?STORE, stream_A, [])),

    teardown().

persist_2_streams_event_test() ->
    setup(),
    ?assertMatch({ok, _}, event_sourcing_store:start(?STORE)),
    Timestamp = calendar:universal_time(),
    Events =
        [event_sourcing_store:new_event(stream_A,
                                        user,
                                        user_registered,
                                        1,
                                        Timestamp,
                                        {"John Doe"}),
         event_sourcing_store:new_event(stream_B,
                                        user,
                                        user_registered,
                                        1,
                                        Timestamp,
                                        {"Jane Doe"})],
    lists:foreach(fun({Index, It}) ->
                     ?assertMatch(ok, event_sourcing_store:persist_event(?STORE, It)),
                     ?assertEqual(Index, table_count(?STORE:table_name(events)))
                  end,
                  lists:zip(
                      lists:seq(1, length(Events)), Events)),

    Evt1 = lists:nth(1, Events),
    ?assertMatch({ok, [Evt1]}, event_sourcing_store:retrieve_events(?STORE, stream_A, [])),
    Evt2 = lists:nth(2, Events),
    ?assertMatch({ok, [Evt2]}, event_sourcing_store:retrieve_events(?STORE, stream_B, [])),

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

    lists:foreach(fun(It) -> ?assertMatch(ok, event_sourcing_store:persist_event(?STORE, It))
                  end,
                  Events),

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
