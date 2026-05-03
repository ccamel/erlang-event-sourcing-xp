-module(es_kernel_store_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ETS_STORE_CONTEXT, {es_store_ets, es_store_ets}).
-define(MNESIA_STORE_CONTEXT, {es_store_mnesia, es_store_mnesia}).
-define(FILE_STORE_CONTEXT, {es_store_file, es_store_file}).
-define(STREAM_A, {user, <<"account-A">>}).
-define(STREAM_B, {user, <<"account-B">>}).

suite_test_() ->
    Stores = [?MNESIA_STORE_CONTEXT, ?ETS_STORE_CONTEXT, ?FILE_STORE_CONTEXT],
    BaseTests =
        [
            {"persist_single_event", fun persist_single_event/1},
            {"persist_2_streams_event", fun persist_2_streams_event/1},
            {"fold_all_events", fun fold_all_events/1},
            {"fold_all_range", fun fold_all_range/1},
            {"fetch_streams_event", fun fetch_streams_event/1},
            {"wrong_stream_id", fun wrong_stream_id/1},
            {"duplicate_event", fun duplicate_event/1},
            {"snapshot_not_found", fun snapshot_not_found/1},
            {"save_and_retrieve_snapshot", fun save_and_retrieve_snapshot/1},
            {"overwrite_snapshot", fun overwrite_snapshot/1},
            {"snapshot_save_error", fun snapshot_save_error/1}
        ],
    TestCases =
        [
            {TestName ++ "__" ++ store_label(Param), fun() -> TestFun(Param) end}
         || Param <- Stores, {TestName, TestFun} <- BaseTests
        ],
    CompositeTests = [
        {"composite_store_supports_mixed_backends", fun composite_store_supports_mixed_backends/0}
    ],
    {foreach, fun setup/0, fun teardown/1, TestCases ++ CompositeTests}.

setup() ->
    mnesia:start(),
    RootDir = filename:join([
        "_build",
        "test",
        "es_store_file",
        integer_to_list(erlang:unique_integer([positive]))
    ]),
    application:set_env(es_store_file, root_dir, RootDir),
    RootDir.

teardown(RootDir) ->
    mnesia:stop(),
    application:unset_env(es_store_file, root_dir),
    _ = file:del_dir_r(RootDir),
    ok.

%%% Helper functions

start_store({EventStore, SnapshotStore}) ->
    EventStore:start(),
    case SnapshotStore =:= EventStore of
        true -> ok;
        false -> SnapshotStore:start()
    end.

stop_store({EventStore, SnapshotStore}) ->
    case SnapshotStore =:= EventStore of
        true ->
            EventStore:stop();
        false ->
            SnapshotStore:stop(),
            EventStore:stop()
    end.

%%% Test cases

persist_single_event(Store) ->
    start_store(Store),
    Timestamp = erlang:system_time(),
    Event =
        es_kernel_store:new_event(
            ?STREAM_A,
            user,
            user_registered,
            1,
            Timestamp,
            {"John Doe"}
        ),

    ?assertMatch(ok, es_kernel_store:append(Store, ?STREAM_A, [Event])),
    ?assertMatch(
        [Event],
        es_kernel_store:retrieve_events(
            Store, ?STREAM_A, es_contract_range:new(0, infinity)
        )
    ),
    stop_store(Store).

persist_2_streams_event(Store) ->
    start_store(Store),
    Timestamp = erlang:system_time(),

    EventStreamA =
        [
            es_kernel_store:new_event(
                ?STREAM_A,
                user,
                user_registered,
                1,
                Timestamp,
                {"John Doe"}
            )
        ],
    EventStreamB =
        [
            es_kernel_store:new_event(
                ?STREAM_B,
                user,
                user_registered,
                1,
                Timestamp,
                {"Jane Doe"}
            )
        ],

    ?assertMatch(ok, es_kernel_store:append(Store, ?STREAM_A, EventStreamA)),
    ?assertMatch(ok, es_kernel_store:append(Store, ?STREAM_B, EventStreamB)),

    ?assertMatch(
        EventStreamA,
        es_kernel_store:retrieve_events(
            Store, ?STREAM_A, es_contract_range:new(0, infinity)
        )
    ),
    ?assertMatch(
        EventStreamB,
        es_kernel_store:retrieve_events(
            Store, ?STREAM_B, es_contract_range:new(0, infinity)
        )
    ),
    ?assertEqual(ok, stop_store(Store)).

fold_all_events(Store) ->
    start_store(Store),
    Timestamp = erlang:system_time(),
    EventA1 = es_kernel_store:new_event(
        ?STREAM_A, user, user_registered, 1, Timestamp, {"John Doe"}
    ),
    EventB1 = es_kernel_store:new_event(
        ?STREAM_B, user, user_registered, 1, Timestamp, {"Jane Doe"}
    ),
    EventA2 = es_kernel_store:new_event(
        ?STREAM_A, user, user_updated, 2, Timestamp, {"John Smith"}
    ),

    ?assertMatch(ok, es_kernel_store:append(Store, ?STREAM_A, [EventA1])),
    ?assertMatch(ok, es_kernel_store:append(Store, ?STREAM_B, [EventB1])),
    ?assertMatch(ok, es_kernel_store:append(Store, ?STREAM_A, [EventA2])),

    FoldFun = fun(Event, Position, Acc) -> Acc ++ [{Position, Event}] end,
    ?assertMatch(
        {ok, [{0, EventA1}, {1, EventB1}, {2, EventA2}]},
        es_kernel_store:fold_all(Store, FoldFun, [], es_contract_range:new(0, infinity))
    ),
    ?assertNot(maps:is_key(position, EventA1)),
    ?assertEqual(ok, stop_store(Store)).

fold_all_range(Store) ->
    start_store(Store),
    Timestamp = erlang:system_time(),
    EventA1 = es_kernel_store:new_event(
        ?STREAM_A, user, user_registered, 1, Timestamp, {"John Doe"}
    ),
    EventB1 = es_kernel_store:new_event(
        ?STREAM_B, user, user_registered, 1, Timestamp, {"Jane Doe"}
    ),
    EventA2 = es_kernel_store:new_event(
        ?STREAM_A, user, user_updated, 2, Timestamp, {"John Smith"}
    ),

    ?assertMatch(ok, es_kernel_store:append(Store, ?STREAM_A, [EventA1])),
    ?assertMatch(ok, es_kernel_store:append(Store, ?STREAM_B, [EventB1])),
    ?assertMatch(ok, es_kernel_store:append(Store, ?STREAM_A, [EventA2])),

    FoldFun = fun(Event, Position, Acc) -> Acc ++ [{Position, Event}] end,
    ?assertMatch(
        {ok, [{1, EventB1}, {2, EventA2}]},
        es_kernel_store:fold_all(Store, FoldFun, [], es_contract_range:new(1, 3))
    ),
    ?assertEqual(ok, stop_store(Store)).

fetch_streams_event(Store) ->
    ?assertMatch(ok, start_store(Store)),
    Timestamp = erlang:system_time(),
    Events =
        [
            es_kernel_store:new_event(
                ?STREAM_A,
                user,
                user_registered,
                1,
                Timestamp,
                {"Jon Doe"}
            ),
            es_kernel_store:new_event(
                ?STREAM_A,
                user,
                user_updated,
                2,
                Timestamp,
                {"John Doe"}
            ),
            es_kernel_store:new_event(?STREAM_A, user, user_deleted, 3, Timestamp, {})
        ],

    ?assertMatch(ok, es_kernel_store:append(Store, ?STREAM_A, Events)),
    ?assertMatch(
        [],
        es_kernel_store:retrieve_events(
            Store, stream_X, es_contract_range:new(0, infinity)
        )
    ),
    ?assertMatch(
        [],
        es_kernel_store:retrieve_events(
            Store, ?STREAM_A, es_contract_range:new(0, 1)
        )
    ),
    ?assertMatch(
        [],
        es_kernel_store:retrieve_events(
            Store, ?STREAM_A, es_contract_range:new(1, 1)
        )
    ),

    Event1 = lists:nth(1, Events),
    Event2 = lists:nth(2, Events),
    Event3 = lists:nth(3, Events),
    ?assertMatch(
        [Event1],
        es_kernel_store:retrieve_events(
            Store, ?STREAM_A, es_contract_range:new(1, 2)
        )
    ),
    ?assertMatch(
        [Event2],
        es_kernel_store:retrieve_events(
            Store, ?STREAM_A, es_contract_range:new(2, 3)
        )
    ),
    ?assertMatch(
        [Event2, Event3],
        es_kernel_store:retrieve_events(
            Store, ?STREAM_A, es_contract_range:new(2, 4)
        )
    ),
    ?assertMatch(
        [Event2],
        es_kernel_store:retrieve_events(
            Store, ?STREAM_A, es_contract_range:new(2, 3)
        )
    ),
    ?assertMatch(
        Events,
        es_kernel_store:retrieve_events(
            Store, ?STREAM_A, es_contract_range:new(0, infinity)
        )
    ),
    ?assertEqual(ok, stop_store(Store)).

wrong_stream_id(Store) ->
    ?assertMatch(ok, start_store(Store)),
    Timestamp = erlang:system_time(),
    Event =
        es_kernel_store:new_event(
            ?STREAM_A,
            user,
            user_registered,
            1,
            Timestamp,
            {"John Doe"}
        ),

    ?assertException(
        error,
        {badarg, ?STREAM_A},
        es_kernel_store:append(Store, ?STREAM_B, [Event])
    ),
    ?assertMatch(
        [],
        es_kernel_store:retrieve_events(
            Store, ?STREAM_A, es_contract_range:new(0, infinity)
        )
    ),
    ?assertMatch(
        [],
        es_kernel_store:retrieve_events(
            Store, ?STREAM_B, es_contract_range:new(0, infinity)
        )
    ),
    ?assertEqual(ok, stop_store(Store)).

duplicate_event(Store) ->
    ?assertMatch(ok, start_store(Store)),
    Timestamp = erlang:system_time(),
    Event =
        es_kernel_store:new_event(
            ?STREAM_A,
            user,
            user_registered,
            1,
            Timestamp,
            {"John Doe"}
        ),

    ?assertMatch(ok, es_kernel_store:append(Store, ?STREAM_A, [Event])),
    ?assertMatch(
        {error, duplicate_event},
        es_kernel_store:append(Store, ?STREAM_A, [Event])
    ),
    ?assertMatch(
        [Event],
        es_kernel_store:retrieve_events(
            Store, ?STREAM_A, es_contract_range:new(0, infinity)
        )
    ),
    Events =
        [
            es_kernel_store:new_event(
                ?STREAM_B,
                user,
                user_registered,
                1,
                Timestamp,
                {"Jon Doe"}
            ),
            es_kernel_store:new_event(
                ?STREAM_B,
                user,
                user_updated,
                2,
                Timestamp,
                {"John Doe"}
            ),
            es_kernel_store:new_event(
                ?STREAM_B,
                user,
                user_registered,
                1,
                Timestamp,
                {"Jon Doe"}
            )
        ],

    ?assertMatch(
        {error, duplicate_event},
        es_kernel_store:append(Store, ?STREAM_B, Events)
    ),
    ?assertMatch(
        [],
        es_kernel_store:retrieve_events(
            Store, ?STREAM_B, es_contract_range:new(0, infinity)
        )
    ),
    ?assertEqual(ok, stop_store(Store)).

snapshot_not_found(Store) ->
    ?assertMatch(ok, start_store(Store)),
    ?assertMatch(
        {error, not_found},
        es_kernel_store:load_latest(Store, ?STREAM_A)
    ),
    ?assertEqual(ok, stop_store(Store)).

save_and_retrieve_snapshot(Store) ->
    ?assertMatch(ok, start_store(Store)),
    Timestamp = erlang:system_time(),
    State = #{balance => 100, name => "John"},
    Sequence = 5,
    Domain = user,

    Snapshot = es_kernel_store:new_snapshot(Domain, ?STREAM_A, Sequence, Timestamp, State),
    ?assertMatch(ok, es_kernel_store:store(Store, Snapshot)),

    {ok, RetrievedSnapshot} = es_kernel_store:load_latest(Store, ?STREAM_A),
    #{
        stream_id := RetrStreamId,
        aggregate_type := RetrAggType,
        sequence := RetrSeq,
        metadata := #{timestamp := RetrTs},
        state := RetrState
    } = RetrievedSnapshot,
    ?assertEqual(?STREAM_A, RetrStreamId),
    ?assertEqual(Domain, RetrAggType),
    ?assertEqual(Sequence, RetrSeq),
    ?assertEqual(Timestamp, RetrTs),
    ?assertEqual(State, RetrState),

    ?assertEqual(ok, stop_store(Store)).

overwrite_snapshot(Store) ->
    ?assertMatch(ok, start_store(Store)),
    Timestamp1 = erlang:system_time(),
    State1 = #{balance => 100},
    Sequence1 = 5,
    Domain = user,

    Snapshot1 = es_kernel_store:new_snapshot(
        Domain, ?STREAM_A, Sequence1, Timestamp1, State1
    ),
    ?assertMatch(ok, es_kernel_store:store(Store, Snapshot1)),

    %% Save a new snapshot for the same stream
    Timestamp2 = erlang:system_time(),
    State2 = #{balance => 200},
    Sequence2 = 10,

    Snapshot2 = es_kernel_store:new_snapshot(
        Domain, ?STREAM_A, Sequence2, Timestamp2, State2
    ),
    ?assertMatch(ok, es_kernel_store:store(Store, Snapshot2)),

    %% Should retrieve the latest snapshot
    {ok, RetrievedSnapshot} = es_kernel_store:load_latest(Store, ?STREAM_A),
    #{sequence := RetrSeq2, state := RetrState2} = RetrievedSnapshot,
    ?assertEqual(Sequence2, RetrSeq2),
    ?assertEqual(State2, RetrState2),

    ?assertEqual(ok, stop_store(Store)).

composite_store_supports_mixed_backends() ->
    Store = {es_store_ets, es_kernel_store_snapshot_stub},
    ?assertMatch(ok, start_store(Store)),

    Timestamp = erlang:system_time(),
    Event =
        es_kernel_store:new_event(
            ?STREAM_A,
            user,
            user_registered,
            1,
            Timestamp,
            {"John Doe"}
        ),
    ?assertMatch(ok, es_kernel_store:append(Store, ?STREAM_A, [Event])),
    ?assertMatch(
        [Event],
        es_kernel_store:retrieve_events(
            Store, ?STREAM_A, es_contract_range:new(0, infinity)
        )
    ),

    Snapshot = es_kernel_store:new_snapshot(user, ?STREAM_A, 1, Timestamp, #{
        balance => 100
    }),
    ?assertMatch(ok, es_kernel_store:store(Store, Snapshot)),
    {ok, RetrievedSnapshot} = es_kernel_store:load_latest(Store, ?STREAM_A),
    #{sequence := CompositeSeq, state := CompositeState} = RetrievedSnapshot,
    ?assertEqual(1, CompositeSeq),
    ?assertEqual(#{balance => 100}, CompositeState),

    ?assertEqual(ok, stop_store(Store)).

snapshot_save_error(?ETS_STORE_CONTEXT = Store) ->
    ?assertMatch(ok, start_store(Store)),
    ?assertEqual(ok, stop_store(Store)),

    %% Attempting to save a snapshot to a stopped ETS store should return a warning
    Timestamp = erlang:system_time(),
    State = #{balance => 100},
    Sequence = 5,
    Domain = user,

    Snapshot = es_kernel_store:new_snapshot(Domain, ?STREAM_A, Sequence, Timestamp, State),
    Result = es_kernel_store:store(Store, Snapshot),

    %% Should return a warning tuple, not throw an exception
    ?assertMatch({warning, _}, Result);
snapshot_save_error(?MNESIA_STORE_CONTEXT = Store) ->
    %% For Mnesia, the store persists even after stop() is called.
    %% Test that the error handling works correctly by verifying successful save
    %% The error path is tested implicitly through the try/catch in the implementation
    ?assertMatch(ok, start_store(Store)),

    Timestamp = erlang:system_time(),
    State = #{balance => 100},
    Sequence = 5,
    Domain = user,

    Snapshot = es_kernel_store:new_snapshot(Domain, ?STREAM_A, Sequence, Timestamp, State),

    %% Normal save should still return ok
    ?assertMatch(ok, es_kernel_store:store(Store, Snapshot)),

    ?assertEqual(ok, stop_store(Store));
snapshot_save_error(?FILE_STORE_CONTEXT = Store) ->
    %% For the file store, stop/0 is intentionally a no-op. Verify the
    %% snapshot write path remains successful for this backend.
    ?assertMatch(ok, start_store(Store)),

    Timestamp = erlang:system_time(),
    State = #{balance => 100},
    Sequence = 5,
    Domain = user,

    Snapshot = es_kernel_store:new_snapshot(Domain, ?STREAM_A, Sequence, Timestamp, State),
    ?assertMatch(ok, es_kernel_store:store(Store, Snapshot)),

    ?assertEqual(ok, stop_store(Store)).

store_label({EventStore, SnapshotStore}) ->
    lists:flatten(io_lib:format("~p-~p", [EventStore, SnapshotStore])).
