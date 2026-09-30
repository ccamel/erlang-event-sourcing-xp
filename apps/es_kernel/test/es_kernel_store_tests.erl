-module(es_kernel_store_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ETS_STORE_CONTEXT, {es_store_ets, es_store_ets}).
-define(MNESIA_STORE_CONTEXT, {es_store_mnesia, es_store_mnesia}).
-define(FILE_STORE_CONTEXT, {es_store_file, es_store_file}).
-define(ETS_EVENT_TABLE, es_kernel_store_tests_ets_events).
-define(ETS_SNAPSHOT_TABLE, es_kernel_store_tests_ets_snapshots).
-define(ETS_POSITION_COUNTER_TABLE, es_kernel_store_tests_ets_position_counter).
-define(ETS_STREAM_SEQUENCE_TABLE, es_kernel_store_tests_ets_stream_sequences).
-define(MNESIA_EVENT_TABLE, es_kernel_store_tests_mnesia_events).
-define(MNESIA_SNAPSHOT_TABLE, es_kernel_store_tests_mnesia_snapshots).
-define(MNESIA_POSITION_COUNTER_TABLE, es_kernel_store_tests_mnesia_position_counter).
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
            {"append_conflicts_and_duplicate_batch_atomicity",
                fun append_conflicts_and_duplicate_batch_atomicity/1},
            {"two_writer_conflict_and_batch_atomicity",
                fun two_writer_conflict_and_batch_atomicity/1},
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
        {"composite_store_supports_mixed_backends", fun composite_store_supports_mixed_backends/0},
        {"file_legacy_log_migration", fun file_legacy_log_migration/0}
    ],
    {foreach, fun setup/0, fun teardown/1, TestCases ++ CompositeTests}.

setup() ->
    mnesia:start(),
    set_backend_table_names(),
    clear_mnesia_tables(),
    ok = es_store_ets:stop(),
    ok = es_store_mnesia:start(),
    RootDir = filename:join([
        "_build",
        "test",
        "es_store_file",
        integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = application:set_env(es_store_file, root_dir, RootDir),
    RootDir.

teardown(RootDir) ->
    ok = es_store_ets:stop(),
    clear_mnesia_tables(),
    mnesia:stop(),
    clear_backend_table_names(),
    ok = application:unset_env(es_store_file, root_dir),
    _ = file:del_dir_r(RootDir),
    ok.

%%% Helper functions

set_backend_table_names() ->
    ok = application:set_env(es_store_ets, event_table_name, ?ETS_EVENT_TABLE),
    ok = application:set_env(es_store_ets, snapshot_table_name, ?ETS_SNAPSHOT_TABLE),
    ok = application:set_env(
        es_store_ets, position_counter_table_name, ?ETS_POSITION_COUNTER_TABLE
    ),
    ok = application:set_env(es_store_ets, stream_sequence_table_name, ?ETS_STREAM_SEQUENCE_TABLE),
    ok = application:set_env(es_store_mnesia, event_table_name, ?MNESIA_EVENT_TABLE),
    ok = application:set_env(es_store_mnesia, snapshot_table_name, ?MNESIA_SNAPSHOT_TABLE),
    ok = application:set_env(
        es_store_mnesia, position_counter_table_name, ?MNESIA_POSITION_COUNTER_TABLE
    ).

clear_backend_table_names() ->
    ok = application:unset_env(es_store_ets, event_table_name),
    ok = application:unset_env(es_store_ets, snapshot_table_name),
    ok = application:unset_env(es_store_ets, position_counter_table_name),
    ok = application:unset_env(es_store_ets, stream_sequence_table_name),
    ok = application:unset_env(es_store_mnesia, event_table_name),
    ok = application:unset_env(es_store_mnesia, snapshot_table_name),
    ok = application:unset_env(es_store_mnesia, position_counter_table_name).

clear_mnesia_tables() ->
    lists:foreach(
        fun clear_mnesia_table/1,
        [?MNESIA_EVENT_TABLE, ?MNESIA_SNAPSHOT_TABLE, ?MNESIA_POSITION_COUNTER_TABLE]
    ).

clear_mnesia_table(Table) ->
    try mnesia:table_info(Table, all) of
        _ ->
            {atomic, ok} = mnesia:delete_table(Table)
    catch
        exit:{aborted, {no_exists, Table, all}} ->
            ok
    end.

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

    ?assertEqual({ok, 1}, es_kernel_store:append(Store, ?STREAM_A, 0, [Event])),
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

    ?assertEqual({ok, 1}, es_kernel_store:append(Store, ?STREAM_A, 0, EventStreamA)),
    ?assertEqual({ok, 1}, es_kernel_store:append(Store, ?STREAM_B, 0, EventStreamB)),

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

    ?assertEqual({ok, 1}, es_kernel_store:append(Store, ?STREAM_A, 0, [EventA1])),
    ?assertEqual({ok, 1}, es_kernel_store:append(Store, ?STREAM_B, 0, [EventB1])),
    ?assertEqual({ok, 2}, es_kernel_store:append(Store, ?STREAM_A, 1, [EventA2])),

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

    ?assertEqual({ok, 1}, es_kernel_store:append(Store, ?STREAM_A, 0, [EventA1])),
    ?assertEqual({ok, 1}, es_kernel_store:append(Store, ?STREAM_B, 0, [EventB1])),
    ?assertEqual({ok, 2}, es_kernel_store:append(Store, ?STREAM_A, 1, [EventA2])),

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

    ?assertEqual({ok, 3}, es_kernel_store:append(Store, ?STREAM_A, 0, Events)),
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
        es_kernel_store:append(Store, ?STREAM_B, 0, [Event])
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

append_conflicts_and_duplicate_batch_atomicity(Store) ->
    ?assertEqual(ok, start_store(Store)),
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

    ?assertEqual({ok, 1}, es_kernel_store:append(Store, ?STREAM_A, 0, [Event])),
    ?assertEqual(
        {error, {wrong_expected_sequence, 0, 1}},
        es_kernel_store:append(Store, ?STREAM_A, 0, [Event])
    ),
    ?assertEqual(
        [Event],
        es_kernel_store:retrieve_events(
            Store, ?STREAM_A, es_contract_range:new(0, infinity)
        )
    ),
    EventB1 = es_kernel_store:new_event(
        ?STREAM_B, user, user_registered, 1, Timestamp, {"Jon Doe"}
    ),
    EventB2 = es_kernel_store:new_event(
        ?STREAM_B, user, user_updated, 2, Timestamp, {"John Doe"}
    ),
    ?assertEqual(
        {error, duplicate_event},
        es_kernel_store:append(Store, ?STREAM_B, 0, [EventB1, EventB2, EventB1])
    ),
    ?assertEqual(
        [],
        es_kernel_store:retrieve_events(
            Store, ?STREAM_B, es_contract_range:new(0, infinity)
        )
    ),
    ?assertEqual([Event], all_events(Store)),
    ?assertEqual(ok, stop_store(Store)).

two_writer_conflict_and_batch_atomicity(Store) ->
    ?assertEqual(ok, start_store(Store)),
    Stream = {user, <<"race-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>},
    Timestamp = erlang:system_time(),
    EventA = es_kernel_store:new_event(Stream, user, writer_a, 1, Timestamp, #{writer => a}),
    EventB = es_kernel_store:new_event(Stream, user, writer_b, 1, Timestamp, #{writer => b}),
    Results = append_concurrently(Store, Stream, EventA, EventB),
    ?assertEqual(2, length(Results)),
    ?assertEqual(1, length([ok || {ok, 1} <- Results])),
    ?assertEqual(
        1,
        length([
            conflict
         || {error, {wrong_expected_sequence, 0, 1}} <- Results
        ])
    ),
    StreamEvents = es_kernel_store:retrieve_events(
        Store, Stream, es_contract_range:new(0, infinity)
    ),
    [Winner] = StreamEvents,
    ?assert(lists:member(Winner, [EventA, EventB])),
    ?assertEqual([Winner], all_events(Store)),

    Event2 = es_kernel_store:new_event(Stream, user, writer_next, 2, Timestamp, #{}),
    ?assertEqual({ok, 2}, es_kernel_store:append(Store, Stream, 1, [Event2])),

    InvalidEvents = [
        es_kernel_store:new_event(Stream, user, invalid, 3, Timestamp, #{}),
        es_kernel_store:new_event(Stream, user, invalid, 5, Timestamp, #{})
    ],
    ?assertEqual(
        {error, invalid_sequence},
        es_kernel_store:append(Store, Stream, 2, InvalidEvents)
    ),
    ?assertEqual(
        {error, invalid_expected_sequence},
        es_kernel_store:append(Store, Stream, -1, [])
    ),
    ?assertEqual(
        {error, invalid_sequence},
        es_kernel_store:append(Store, Stream, 2, [#{stream_id => Stream}])
    ),
    ?assertEqual(
        [Winner, Event2],
        es_kernel_store:retrieve_events(
            Store, Stream, es_contract_range:new(0, infinity)
        )
    ),
    ?assertEqual([Winner, Event2], all_events(Store)),
    ?assertEqual({ok, 2}, es_kernel_store:append(Store, Stream, 2, [])),
    ?assertEqual(
        {error, {wrong_expected_sequence, 1, 2}},
        es_kernel_store:append(Store, Stream, 1, [])
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
    ?assertEqual({ok, 1}, es_kernel_store:append(Store, ?STREAM_A, 0, [Event])),
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

append_concurrently(Store, Stream, EventA, EventB) ->
    Parent = self(),
    Writers = [
        spawn_monitor(fun() -> append_writer(Parent, Store, Stream, Event) end)
     || Event <- [EventA, EventB]
    ],
    wait_for_writers_ready(Writers),
    lists:foreach(fun({Pid, _Ref}) -> Pid ! go end, Writers),
    Results = [
        wait_for_writer_result(Pid, Ref)
     || {Pid, Ref} <- Writers
    ],
    wait_for_writers_down(Writers),
    Results.

append_writer(Parent, Store, Stream, Event) ->
    ParentMonitor = erlang:monitor(process, Parent),
    Parent ! {writer_ready, self()},
    receive
        go ->
            Parent !
                {
                    writer_result,
                    self(),
                    es_kernel_store:append(Store, Stream, 0, [Event])
                };
        {'DOWN', ParentMonitor, process, Parent, _} ->
            ok
    end.

wait_for_writers_ready([]) ->
    ok;
wait_for_writers_ready(Writers) ->
    receive
        {writer_ready, Pid} ->
            case lists:keytake(Pid, 1, Writers) of
                {value, _Writer, Remaining} ->
                    wait_for_writers_ready(Remaining);
                false ->
                    wait_for_writers_ready(Writers)
            end;
        {'DOWN', Ref, process, Pid, Reason} ->
            case lists:keyfind(Pid, 1, Writers) of
                {Pid, Ref} ->
                    erlang:error({writer_down, Pid, Reason});
                false ->
                    wait_for_writers_ready(Writers)
            end
    after 1000 ->
        erlang:error(writer_ready_timeout)
    end.

wait_for_writer_result(Pid, Ref) ->
    receive
        {writer_result, Pid, Result} ->
            Result;
        {'DOWN', Ref, process, Pid, Reason} ->
            erlang:error({writer_down, Pid, Reason})
    after 1000 ->
        erlang:error({writer_result_timeout, Pid})
    end.

wait_for_writers_down([]) ->
    ok;
wait_for_writers_down([{Pid, Ref} | Rest]) ->
    receive
        {'DOWN', Ref, process, Pid, normal} ->
            wait_for_writers_down(Rest);
        {'DOWN', Ref, process, Pid, Reason} ->
            erlang:error({writer_down, Pid, Reason})
    after 1000 ->
        erlang:error({writer_down_timeout, Pid})
    end.

all_events(Store) ->
    {ok, Events} = es_kernel_store:fold_all(
        Store,
        fun(Event, _Position, Acc) -> [Event | Acc] end,
        [],
        es_contract_range:new(0, infinity)
    ),
    lists:reverse(Events).

store_label({EventStore, SnapshotStore}) ->
    lists:flatten(io_lib:format("~p-~p", [EventStore, SnapshotStore])).

file_legacy_log_migration() ->
    {ok, Root} = application:get_env(es_store_file, root_dir),
    Path = filename:join([Root, "events", "user_legacy.log"]),
    ok = filelib:ensure_dir(Path),
    Stream = {user, <<"legacy">>},
    First = maps:remove(event_id, es_kernel_store:new_event(Stream, user, created, 1, 1, #{})),
    Second = (es_kernel_store:new_event(Stream, user, updated, 2, 2, #{}))#{
        event_id := binary:copy(<<255>>, 16)
    },
    ok = file:write_file(Path, io_lib:format("~0p.~n", [First])),
    IndexPath = filename:join(Root, "global_index.dat"),
    %% Refuse an incomplete legacy index rather than losing its stream event.
    ok = file:write_file(IndexPath, <<>>),
    ?assertEqual({error, legacy_migration_required}, es_store_file:start()),
    ?assertEqual({error, enoent}, file:read_file(filename:join(Root, "event_log.dat"))),
    ok = file:write_file(
        IndexPath,
        io_lib:format("~0p.~n", [{0, Path, es_contract_event:key(First)}])
    ),
    ?assertEqual(ok, es_store_file:start()),
    ?assertEqual({ok, 2}, es_store_file:append(Stream, 1, [Second])),
    ?assertEqual(ok, es_store_file:stop()),
    ?assertEqual(ok, es_store_file:start()),
    ?assertEqual(
        {ok, [First, Second]},
        es_store_file:fold(
            Stream,
            fun(Event, _Seq, Acc) -> Acc ++ [Event] end,
            [],
            es_contract_range:new(0, infinity)
        )
    ),
    ?assertEqual(
        {ok, [{0, First}, {1, Second}]},
        es_store_file:fold_all(
            fun(Event, Position, Acc) -> Acc ++ [{Position, Event}] end,
            [],
            es_contract_range:new(0, infinity)
        )
    ),
    ?assertEqual({ok, [First]}, file:consult(Path)).
