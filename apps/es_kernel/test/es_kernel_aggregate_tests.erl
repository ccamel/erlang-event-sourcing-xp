-module(es_kernel_aggregate_tests).

-include_lib("eunit/include/eunit.hrl").

suite_test_() ->
    TestCases =
        [
            {"aggregate_behaviour", fun aggregate_behaviour/0},
            {"aggregate_passivation", fun aggregate_passivation/0},
            {"aggregate_invalid_command", fun aggregate_invalid_command/0},
            {"aggregate_snapshot_creation", fun aggregate_snapshot_creation/0},
            {"aggregate_snapshot_rehydration", fun aggregate_snapshot_rehydration/0},
            {"aggregate_custom_now_fun", fun aggregate_custom_now_fun/0}
        ],
    {foreach, fun setup/0, fun teardown/1, TestCases}.

setup() ->
    application:load(es_kernel),
    application:set_env(es_kernel, event_store, es_store_ets),
    application:set_env(es_kernel, snapshot_store, es_store_ets),
    StoreContext = es_kernel_app:get_store_context(),
    {EventStore, SnapshotStore} = StoreContext,
    EventStore:start(),
    case SnapshotStore =:= EventStore of
        true -> ok;
        false -> SnapshotStore:start()
    end,
    StoreContext.

teardown({EventStore, SnapshotStore}) ->
    case SnapshotStore =:= EventStore of
        true ->
            EventStore:stop();
        false ->
            SnapshotStore:stop(),
            EventStore:stop()
    end.

%%%  Test cases

-define(assertState(Pid, Id, ExpectedState, ExpectedSeq), begin
    StoreCtx = es_kernel_app:get_store_context(),
    StreamId = {bank_account_aggregate, Id},
    ?assertMatch(
        {state, bank_account_aggregate, StoreCtx, StreamId, ExpectedState, ExpectedSeq, _, _, _, _},
        sys:get_state(Pid)
    )
end).

cmd(Type, Id, Payload) ->
    es_contract_command:new(
        bank_account_aggregate,
        Type,
        Id,
        0,
        #{},
        Payload
    ).

aggregate_behaviour() ->
    {Id, Pid} = start_test_account(5000),

    ?assertState(Pid, Id, #{balance := 0}, 0),

    ?assertEqual(ok, es_kernel_aggregate:execute(Pid, cmd(deposit, Id, #{amount => 100}))),
    ?assertState(Pid, Id, #{balance := 100}, 1),

    ?assertEqual(ok, es_kernel_aggregate:execute(Pid, cmd(deposit, Id, #{amount => 100}))),
    ?assertState(Pid, Id, #{balance := 200}, 2),

    ?assertEqual(ok, es_kernel_aggregate:execute(Pid, cmd(withdraw, Id, #{amount => 50}))),
    ?assertState(Pid, Id, #{balance := 150}, 3).

aggregate_passivation() ->
    {Id, Pid} = start_test_account(1000),

    ?assertEqual(ok, es_kernel_aggregate:execute(Pid, cmd(deposit, Id, #{amount => 100}))),
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid, cmd(withdraw, Id, #{amount => 25}))),

    ?assertState(Pid, Id, #{balance := 75}, 2),

    % wait for the aggregate to be passivated
    timer:sleep(2000),

    % check pid is not alive
    ?assertEqual(false, is_process_alive(Pid)),

    % start a new aggregate with the same id and check hydration
    StoreContext = es_kernel_app:get_store_context(),
    StreamId = {bank_account_aggregate, Id},
    {ok, Pid2} =
        es_kernel_aggregate:start_link(
            bank_account_aggregate,
            StoreContext,
            StreamId,
            #{timeout => 5000}
        ),
    ?assertState(Pid2, Id, #{balance := 75}, 2).

aggregate_invalid_command() ->
    {Id, Pid} = start_test_account(5000),

    ?assertEqual(
        {error, invalid_command},
        es_kernel_aggregate:execute(Pid, invalid)
    ),
    ?assertEqual(
        {error, insufficient_funds},
        es_kernel_aggregate:execute(Pid, cmd(withdraw, Id, #{amount => 100}))
    ).

start_test_account(Timeout) ->
    %% Generate unique ID to avoid conflicts between tests
    AggId = list_to_binary("bank-account-" ++ integer_to_list(erlang:unique_integer([positive]))),
    StreamId = {bank_account_aggregate, AggId},
    StoreContext = es_kernel_app:get_store_context(),
    {ok, Pid} =
        es_kernel_aggregate:start_link(
            bank_account_aggregate,
            StoreContext,
            StreamId,
            #{timeout => Timeout}
        ),
    {AggId, Pid}.

start_test_account_with_snapshots(Timeout, SnapshotInterval) ->
    %% Generate unique ID to avoid conflicts between tests
    AggId = list_to_binary("bank-account-" ++ integer_to_list(erlang:unique_integer([positive]))),
    StreamId = {bank_account_aggregate, AggId},
    StoreContext = es_kernel_app:get_store_context(),
    {ok, Pid} =
        es_kernel_aggregate:start_link(
            bank_account_aggregate,
            StoreContext,
            StreamId,
            #{timeout => Timeout, snapshot_interval => SnapshotInterval}
        ),
    {AggId, Pid}.

aggregate_snapshot_creation() ->
    {Id, Pid} = start_test_account_with_snapshots(5000, 3),

    %% Process 5 commands
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid, cmd(deposit, Id, #{amount => 100}))),
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid, cmd(deposit, Id, #{amount => 50}))),
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid, cmd(withdraw, Id, #{amount => 25}))),
    ?assertState(Pid, Id, #{balance := 125}, 3),

    %% Snapshot should be saved at sequence 3 (3 % 3 == 0)
    StoreContext = es_kernel_app:get_store_context(),
    StreamId = {bank_account_aggregate, Id},
    {ok, Snapshot} = es_kernel_store:load_latest(
        StoreContext,
        StreamId
    ),
    ?assertEqual(3, es_kernel_store:snapshot_sequence(Snapshot)),
    ?assertEqual(#{balance => 125}, es_kernel_store:snapshot_state(Snapshot)),

    %% Continue with more commands
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid, cmd(deposit, Id, #{amount => 75}))),
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid, cmd(withdraw, Id, #{amount => 50}))),
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid, cmd(deposit, Id, #{amount => 100}))),
    ?assertState(Pid, Id, #{balance := 250}, 6),

    %% Snapshot should now be at sequence 6 (6 % 3 == 0)
    {ok, Snapshot2} = es_kernel_store:load_latest(
        StoreContext,
        StreamId
    ),
    ?assertEqual(6, es_kernel_store:snapshot_sequence(Snapshot2)),
    ?assertEqual(#{balance => 250}, es_kernel_store:snapshot_state(Snapshot2)).

aggregate_snapshot_rehydration() ->
    %% Generate unique ID to avoid conflicts between tests
    AggId = list_to_binary("bank-account-" ++ integer_to_list(erlang:unique_integer([positive]))),
    StreamId = {bank_account_aggregate, AggId},

    %% First, create an aggregate with snapshots
    StoreContext = es_kernel_app:get_store_context(),
    {ok, Pid1} =
        es_kernel_aggregate:start_link(
            bank_account_aggregate,
            StoreContext,
            StreamId,
            #{timeout => 5000, snapshot_interval => 2}
        ),

    %% Process commands to create events and snapshots
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid1, cmd(deposit, AggId, #{amount => 100}))),
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid1, cmd(deposit, AggId, #{amount => 200}))),
    ?assertState(Pid1, AggId, #{balance := 300}, 2),

    %% Snapshot should exist at sequence 2
    {ok, _Snapshot} = es_kernel_store:load_latest(
        StoreContext,
        StreamId
    ),

    %% Add more events after snapshot
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid1, cmd(withdraw, AggId, #{amount => 50}))),
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid1, cmd(deposit, AggId, #{amount => 150}))),
    ?assertState(Pid1, AggId, #{balance := 400}, 4),

    %% Stop the aggregate
    gen_server:stop(Pid1),

    %% Start a new aggregate with the same ID - should load from snapshot + replay events
    {ok, Pid2} =
        es_kernel_aggregate:start_link(
            bank_account_aggregate,
            StoreContext,
            StreamId,
            #{timeout => 5000}
        ),

    %% Should have rehydrated to sequence 4 by loading snapshot at 2 and replaying events 3,4
    ?assertState(Pid2, AggId, #{balance := 400}, 4).

%% Test that a custom now_fun injected via options is used for event timestamps
aggregate_custom_now_fun() ->
    %% Unique ID
    AggId = list_to_binary("bank-account-" ++ integer_to_list(erlang:unique_integer([positive]))),
    StreamId = {bank_account_aggregate, AggId},

    %% Deterministic timestamp
    Now = 1_234_567_890,

    %% Start aggregate with custom now_fun
    StoreContext = es_kernel_app:get_store_context(),
    {ok, Pid} =
        es_kernel_aggregate:start_link(
            bank_account_aggregate,
            StoreContext,
            StreamId,
            #{timeout => 5000, now_fun => fun() -> Now end}
        ),

    %% Execute a command that will persist an event
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid, cmd(deposit, AggId, #{amount => 42}))),

    %% Retrieve persisted events and assert the timestamp matches the injected Now
    Events = es_kernel_store:retrieve_events(
        StoreContext, StreamId, es_contract_range:new(0, infinity)
    ),
    ?assertEqual(1, length(Events)),
    [Event] = Events,
    ?assertEqual(Now, es_kernel_store:timestamp(Event)).
