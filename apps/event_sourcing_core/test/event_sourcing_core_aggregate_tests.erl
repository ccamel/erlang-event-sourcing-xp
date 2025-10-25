-module(event_sourcing_core_aggregate_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ETS_STORE, {event_sourcing_store_ets, event_sourcing_store_ets}).

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
    event_sourcing_core_store:start(?ETS_STORE).

teardown(_) ->
    event_sourcing_core_store:stop(?ETS_STORE).

%%%  Test cases

-define(assertState(Pid, Id, ExpectedState, ExpectedSeq),
    ?assertMatch(
        {state, bank_account_aggregate, ?ETS_STORE, Id, ExpectedState, ExpectedSeq, _, _, _, _, _,
            _},
        sys:get_state(Pid)
    )
).

aggregate_behaviour() ->
    {Id, Pid} = start_test_account(5000),

    ?assertState(Pid, Id, #{balance := 0}, 0),

    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid, {bank, deposit, Id, 100})),
    ?assertState(Pid, Id, #{balance := 100}, 1),

    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid, {bank, deposit, Id, 100})),
    ?assertState(Pid, Id, #{balance := 200}, 2),

    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid, {bank, withdraw, Id, 50})),
    ?assertState(Pid, Id, #{balance := 150}, 3).

aggregate_passivation() ->
    {Id, Pid} = start_test_account(1000),

    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid, {bank, deposit, Id, 100})),
    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid, {bank, withdraw, Id, 25})),

    ?assertState(Pid, Id, #{balance := 75}, 2),

    % wait for the aggregate to be passivated
    timer:sleep(2000),

    % check pid is not alive
    ?assertEqual(false, is_process_alive(Pid)),

    % start a new aggregate with the same id and check hydration
    {ok, Pid2} =
        event_sourcing_core_aggregate:start_link(
            bank_account_aggregate,
            ?ETS_STORE,
            Id,
            #{timeout => 5000}
        ),
    ?assertState(Pid2, Id, #{balance := 75}, 2).

aggregate_invalid_command() ->
    {Id, Pid} = start_test_account(5000),

    ?assertEqual(
        {error, invalid_command},
        event_sourcing_core_aggregate:dispatch(Pid, invalid)
    ),
    ?assertEqual(
        {error, insufficient_funds},
        event_sourcing_core_aggregate:dispatch(Pid, {bank, withdraw, Id, 100})
    ).

start_test_account(Timeout) ->
    %% Generate unique ID to avoid conflicts between tests
    Id = list_to_binary("bank-account-" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, Pid} =
        event_sourcing_core_aggregate:start_link(
            bank_account_aggregate,
            ?ETS_STORE,
            Id,
            #{timeout => Timeout}
        ),
    {Id, Pid}.

start_test_account_with_snapshots(Timeout, SnapshotInterval) ->
    %% Generate unique ID to avoid conflicts between tests
    Id = list_to_binary("bank-account-" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, Pid} =
        event_sourcing_core_aggregate:start_link(
            bank_account_aggregate,
            ?ETS_STORE,
            Id,
            #{timeout => Timeout, snapshot_interval => SnapshotInterval}
        ),
    {Id, Pid}.

aggregate_snapshot_creation() ->
    {Id, Pid} = start_test_account_with_snapshots(5000, 3),

    %% Process 5 commands
    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid, {bank, deposit, Id, 100})),
    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid, {bank, deposit, Id, 50})),
    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid, {bank, withdraw, Id, 25})),
    ?assertState(Pid, Id, #{balance := 125}, 3),

    %% Snapshot should be saved at sequence 3 (3 % 3 == 0)
    {ok, Snapshot} = event_sourcing_core_store:retrieve_latest_snapshot(
        ?ETS_STORE,
        Id
    ),
    ?assertEqual(3, event_sourcing_core_store:snapshot_sequence(Snapshot)),
    ?assertEqual(#{balance => 125}, event_sourcing_core_store:snapshot_state(Snapshot)),

    %% Continue with more commands
    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid, {bank, deposit, Id, 75})),
    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid, {bank, withdraw, Id, 50})),
    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid, {bank, deposit, Id, 100})),
    ?assertState(Pid, Id, #{balance := 250}, 6),

    %% Snapshot should now be at sequence 6 (6 % 3 == 0)
    {ok, Snapshot2} = event_sourcing_core_store:retrieve_latest_snapshot(
        ?ETS_STORE,
        Id
    ),
    ?assertEqual(6, event_sourcing_core_store:snapshot_sequence(Snapshot2)),
    ?assertEqual(#{balance => 250}, event_sourcing_core_store:snapshot_state(Snapshot2)).

aggregate_snapshot_rehydration() ->
    %% Generate unique ID to avoid conflicts between tests
    Id = list_to_binary("bank-account-" ++ integer_to_list(erlang:unique_integer([positive]))),

    %% First, create an aggregate with snapshots
    {ok, Pid1} =
        event_sourcing_core_aggregate:start_link(
            bank_account_aggregate,
            ?ETS_STORE,
            Id,
            #{timeout => 5000, snapshot_interval => 2}
        ),

    %% Process commands to create events and snapshots
    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid1, {bank, deposit, Id, 100})),
    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid1, {bank, deposit, Id, 200})),
    ?assertState(Pid1, Id, #{balance := 300}, 2),

    %% Snapshot should exist at sequence 2
    {ok, _Snapshot} = event_sourcing_core_store:retrieve_latest_snapshot(
        ?ETS_STORE,
        Id
    ),

    %% Add more events after snapshot
    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid1, {bank, withdraw, Id, 50})),
    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid1, {bank, deposit, Id, 150})),
    ?assertState(Pid1, Id, #{balance := 400}, 4),

    %% Stop the aggregate
    gen_server:stop(Pid1),

    %% Start a new aggregate with the same ID - should load from snapshot + replay events
    {ok, Pid2} =
        event_sourcing_core_aggregate:start_link(
            bank_account_aggregate,
            ?ETS_STORE,
            Id,
            #{timeout => 5000}
        ),

    %% Should have rehydrated to sequence 4 by loading snapshot at 2 and replaying events 3,4
    ?assertState(Pid2, Id, #{balance := 400}, 4).

%% Test that a custom now_fun injected via options is used for event timestamps
aggregate_custom_now_fun() ->
    %% Unique ID
    Id = list_to_binary("bank-account-" ++ integer_to_list(erlang:unique_integer([positive]))),

    %% Deterministic timestamp
    Now = 1_234_567_890,

    %% Start aggregate with custom now_fun
    {ok, Pid} =
        event_sourcing_core_aggregate:start_link(
            bank_account_aggregate,
            ?ETS_STORE,
            Id,
            #{timeout => 5000, now_fun => fun() -> Now end}
        ),

    %% Dispatch a command that will persist an event
    ?assertEqual(ok, event_sourcing_core_aggregate:dispatch(Pid, {bank, deposit, Id, 42})),

    %% Retrieve persisted events and assert the timestamp matches the injected Now
    Events = event_sourcing_core_store:retrieve_events(?ETS_STORE, Id, #{}),
    ?assertEqual(1, length(Events)),
    [Event] = Events,
    ?assertEqual(Now, event_sourcing_core_store:timestamp(Event)).
