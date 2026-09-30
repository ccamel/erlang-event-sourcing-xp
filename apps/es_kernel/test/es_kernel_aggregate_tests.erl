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
            {"aggregate_custom_now_fun", fun aggregate_custom_now_fun/0},
            {"aggregate_concurrent_writers", fun aggregate_concurrent_writers/0},
            {"aggregate_event_context", fun aggregate_event_context/0}
        ],
    {foreach, fun setup/0, fun teardown/1, TestCases}.

setup() ->
    application:load(es_kernel),
    application:set_env(es_kernel, event_store, es_store_ets),
    application:set_env(es_kernel, snapshot_store, es_store_ets),
    %% Register aggregate type mapping for tests
    es_kernel_registry:register(
        bank_account, #{runtime => erlang, module => bank_account_aggregate}
    ),
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
    ?assertMatch(
        {state, bank_account, #{runtime := erlang, module := bank_account_aggregate}, StoreCtx, Id,
            ExpectedState, ExpectedSeq, _, _, _, _},
        sys:get_state(Pid)
    )
end).

cmd(Type, Id, Payload) ->
    es_contract_command:new(
        bank_account,
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
    {ok, Pid2} =
        es_kernel_aggregate:start_link(
            bank_account,
            Id,
            StoreContext,
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
    AggId = integer_to_binary(erlang:unique_integer([monotonic, positive])),
    StoreContext = es_kernel_app:get_store_context(),
    {ok, Pid} =
        es_kernel_aggregate:start_link(
            bank_account,
            AggId,
            StoreContext,
            #{timeout => Timeout}
        ),
    {AggId, Pid}.

start_test_account_with_snapshots(Timeout, SnapshotInterval) ->
    AggId = integer_to_binary(erlang:unique_integer([monotonic, positive])),
    StoreContext = es_kernel_app:get_store_context(),
    {ok, Pid} =
        es_kernel_aggregate:start_link(
            bank_account,
            AggId,
            StoreContext,
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
    StreamId = {bank_account, Id},
    {ok, Snapshot} = es_kernel_store:load_latest(
        StoreContext,
        StreamId
    ),
    #{sequence := SnapshotSeq1, state := SnapshotState1} = Snapshot,
    ?assertEqual(3, SnapshotSeq1),
    ?assertEqual(#{balance => 125}, SnapshotState1),

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
    #{sequence := SnapshotSeq2, state := SnapshotState2} = Snapshot2,
    ?assertEqual(6, SnapshotSeq2),
    ?assertEqual(#{balance => 250}, SnapshotState2).

aggregate_snapshot_rehydration() ->
    AggId = integer_to_binary(erlang:unique_integer([monotonic, positive])),
    StreamId = {bank_account, AggId},

    %% First, create an aggregate with snapshots
    StoreContext = es_kernel_app:get_store_context(),
    {ok, Pid1} =
        es_kernel_aggregate:start_link(
            bank_account,
            AggId,
            StoreContext,
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
            bank_account,
            AggId,
            StoreContext,
            #{timeout => 5000}
        ),

    %% Should have rehydrated to sequence 4 by loading snapshot at 2 and replaying events 3,4
    ?assertState(Pid2, AggId, #{balance := 400}, 4).

%% Test that a custom now_fun injected via options is used for event timestamps
aggregate_custom_now_fun() ->
    AggId = integer_to_binary(erlang:unique_integer([monotonic, positive])),
    StreamId = {bank_account, AggId},

    %% Deterministic timestamp
    Now = 1_234_567_890,

    %% Start aggregate with custom now_fun
    StoreContext = es_kernel_app:get_store_context(),
    {ok, Pid} =
        es_kernel_aggregate:start_link(
            bank_account,
            AggId,
            StoreContext,
            #{timeout => 5000, now_fun => fun() -> Now end}
        ),

    %% Execute a command that will persist an event
    Command = es_contract_command:with_metadata(
        #{timestamp => 0}, cmd(deposit, AggId, #{amount => 42})
    ),
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid, Command)),

    %% Retrieve persisted events and assert the timestamp matches the injected Now
    Events = es_kernel_store:retrieve_events(
        StoreContext, StreamId, es_contract_range:new(0, infinity)
    ),
    [#{metadata := #{timestamp := EventTimestamp}}] = Events,
    ?assertEqual(Now, EventTimestamp).

aggregate_concurrent_writers() ->
    {Id, A} = start_test_account(5000),
    Store = es_kernel_app:get_store_context(),
    {ok, B} = es_kernel_aggregate:start_link(bank_account, Id, Store),
    Parent = self(),
    Ref = make_ref(),
    Writers = [
        spawn_monitor(fun() ->
            Parent ! {Ref, ready, self()},
            receive
                {Ref, go} ->
                    Result = es_kernel_aggregate:execute(
                        Pid, cmd(deposit, Id, #{amount => Amount})
                    ),
                    Parent ! {Ref, Pid, Result}
            end
        end)
     || {Pid, Amount} <- [{A, 100}, {B, 200}]
    ],
    try
        lists:foreach(
            fun({Worker, _}) ->
                receive
                    {Ref, ready, Worker} -> ok
                after 1000 -> error(writer_not_ready)
                end
            end,
            Writers
        ),
        lists:foreach(fun({Worker, _}) -> Worker ! {Ref, go} end, Writers),
        Results = [
            receive
                {Ref, Pid, Result} -> {Pid, Result}
            after 1000 -> error(writer_timeout)
            end
         || _ <- Writers
        ],
        ?assertEqual(
            [ok, {error, {wrong_expected_sequence, 0, 1}}],
            lists:sort([Result || {_, Result} <- Results])
        ),
        [{Loser, _}] = [{Pid, Result} || {Pid, {error, _} = Result} <- Results],
        [#{sequence := 1, payload := #{amount := Balance}}] =
            es_kernel_store:retrieve_events(
                Store, {bank_account, Id}, es_contract_range:new(0, infinity)
            ),
        %% A successful withdrawal proves the losing process survived and refreshed
        %% from the winner's committed history; the rejected deposit was not applied.
        ?assertEqual(
            ok, es_kernel_aggregate:execute(Loser, cmd(withdraw, Id, #{amount => Balance}))
        ),
        ?assertEqual(
            {error, insufficient_funds},
            es_kernel_aggregate:execute(Loser, cmd(withdraw, Id, #{amount => 1}))
        ),
        [#{sequence := 1}, #{sequence := 2, payload := #{amount := Balance}}] =
            es_kernel_store:retrieve_events(
                Store, {bank_account, Id}, es_contract_range:new(0, infinity)
            )
    after
        lists:foreach(
            fun({Worker, Monitor}) ->
                receive
                    {'DOWN', Monitor, process, Worker, normal} -> ok
                after 1000 -> error(writer_did_not_finish)
                end
            end,
            Writers
        ),
        gen_server:stop(A),
        gen_server:stop(B)
    end.

aggregate_event_context() ->
    {Id, Pid} = start_test_account(5000),
    Store = es_kernel_app:get_store_context(),
    Metadata = #{
        correlation_id => <<"request-1">>, causation_id => <<"command-1">>, user_id => <<"user-1">>
    },
    Tags = [<<"tenant:one">>, <<"audit">>],
    Command = es_contract_command:with_tags(
        Tags,
        es_contract_command:with_metadata(Metadata, cmd(deposit, Id, #{amount => 42}))
    ),
    try
        ?assertEqual(ok, es_kernel_aggregate:execute(Pid, Command)),
        ?assertEqual(ok, es_kernel_aggregate:execute(Pid, Command)),
        [First, Second] = es_kernel_store:retrieve_events(
            Store, {bank_account, Id}, es_contract_range:new(0, infinity)
        ),
        #{event_id := FirstId, metadata := StoredMetadata, tags := Tags} = First,
        #{event_id := SecondId} = Second,
        ?assertMatch(<<_:128>>, FirstId),
        ?assertMatch(<<_:128>>, SecondId),
        ?assertNotEqual(FirstId, SecondId),
        ?assertEqual(Metadata, maps:remove(timestamp, StoredMetadata)),
        gen_server:stop(Pid),
        {ok, Rehydrated} = es_kernel_aggregate:start_link(bank_account, Id, Store),
        try
            ?assertEqual(
                ok, es_kernel_aggregate:execute(Rehydrated, cmd(withdraw, Id, #{amount => 84}))
            ),
            [ReplayedFirst, ReplayedSecond, _] = es_kernel_store:retrieve_events(
                Store, {bank_account, Id}, es_contract_range:new(0, infinity)
            ),
            ?assertEqual([First, Second], [ReplayedFirst, ReplayedSecond])
        after
            gen_server:stop(Rehydrated)
        end
    after
        case is_process_alive(Pid) of
            true -> gen_server:stop(Pid);
            false -> ok
        end
    end.
