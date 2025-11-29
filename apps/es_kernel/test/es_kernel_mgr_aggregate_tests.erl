-module(es_kernel_mgr_aggregate_tests).

-include_lib("eunit/include/eunit.hrl").

suite_test_() ->
    TestCases =
        [
            {"aggregate_behaviour", fun aggregate_behaviour/0},
            {"aggregate_passivation", fun aggregate_passivation/0},
            {"aggregate_invalid_command", fun aggregate_invalid_command/0}
        ],
    {foreach, fun setup/0, fun teardown/1, TestCases}.

setup() ->
    %% Set test configuration before starting the application
    application:load(es_kernel),
    application:set_env(es_kernel, event_store, es_store_ets),
    application:set_env(es_kernel, snapshot_store, es_store_ets),
    %% Register aggregate type mapping for tests
    es_kernel_registry:register(bank_account, bank_account_aggregate),

    StoreContext = es_kernel_app:get_store_context(),
    {EventStore, SnapshotStore} = StoreContext,
    EventStore:start(),
    case SnapshotStore =:= EventStore of
        true -> ok;
        false -> SnapshotStore:start()
    end,

    %% Start the aggregate supervisor needed by the manager
    case whereis(es_kernel_aggregate_sup) of
        undefined ->
            {ok, _Pid} = es_kernel_aggregate_sup:start_link();
        _Pid ->
            ok
    end,

    %% Stop the manager if it's already running (from previous test)
    case whereis(es_kernel_mgr_aggregate) of
        undefined ->
            ok;
        MgrPid ->
            unlink(MgrPid),
            exit(MgrPid, kill),
            timer:sleep(10)
    end,

    StoreContext.

teardown({EventStore, SnapshotStore}) ->
    %% Stop the manager if running
    case whereis(es_kernel_mgr_aggregate) of
        undefined ->
            ok;
        MgrPid ->
            unlink(MgrPid),
            exit(MgrPid, kill),
            timer:sleep(10)
    end,

    %% Stop the aggregate supervisor
    case whereis(es_kernel_aggregate_sup) of
        undefined ->
            ok;
        Pid ->
            unlink(Pid),
            exit(Pid, shutdown),
            %% Wait for it to terminate
            timer:sleep(10)
    end,
    case SnapshotStore =:= EventStore of
        true ->
            EventStore:stop();
        false ->
            SnapshotStore:stop(),
            EventStore:stop()
    end.

%%%  Test cases

agg_id(Pid, AggregateType, Id) ->
    Target = {AggregateType, Id},
    {state, _, _, #{Target := AggPid}} = sys:get_state(Pid),
    AggPid.

cmd(Type, Id, Payload) ->
    es_contract_command:new(
        bank_account,
        Type,
        Id,
        0,
        #{},
        Payload
    ).

-define(assertState(Pid, Id, ExpectedState, ExpectedSeq), begin
    StoreCtx = es_kernel_app:get_store_context(),
    ?assertMatch(
        {state, bank_account, bank_account_aggregate, StoreCtx, Id, ExpectedState, ExpectedSeq, _,
            _, _, _},
        sys:get_state(Pid)
    )
end).

aggregate_behaviour() ->
    Pid = start_mgr(5000),
    Id = <<"123">>,

    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, cmd(deposit, Id, #{amount => 100}))
    ),
    ?assertState(agg_id(Pid, bank_account, Id), Id, #{balance := 100}, 1),

    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, cmd(deposit, Id, #{amount => 100}))
    ),
    ?assertState(agg_id(Pid, bank_account, Id), Id, #{balance := 200}, 2),

    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, cmd(withdraw, Id, #{amount => 50}))
    ),
    ?assertState(agg_id(Pid, bank_account, Id), Id, #{balance := 150}, 3),

    ?assertEqual(ok, es_kernel_mgr_aggregate:stop(Pid)).

aggregate_passivation() ->
    Pid = start_mgr(1000),
    Id = <<"123">>,

    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, cmd(deposit, Id, #{amount => 100}))
    ),
    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, cmd(withdraw, Id, #{amount => 25}))
    ),

    ?assertState(agg_id(Pid, bank_account, Id), Id, #{balance := 75}, 2),

    % wait for the aggregate to be passivated
    timer:sleep(2000),

    % check aggregate is no more alive
    {state, _, _, AggPids} = sys:get_state(Pid),
    Key = {bank_account, Id},
    ?assertEqual(false, maps:is_key(Key, AggPids)),

    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, cmd(deposit, Id, #{amount => 30}))
    ),

    ?assertState(agg_id(Pid, bank_account, Id), Id, #{balance := 105}, 3),

    ?assertEqual(ok, es_kernel_mgr_aggregate:stop(Pid)).

aggregate_invalid_command() ->
    Pid = start_mgr(5000),
    Id = <<"123">>,

    ?assertEqual(
        {error, invalid_command},
        es_kernel_mgr_aggregate:dispatch(Pid, invalid)
    ),
    ?assertEqual(
        {error, insufficient_funds},
        es_kernel_mgr_aggregate:dispatch(Pid, cmd(withdraw, Id, #{amount => 100}))
    ),

    ?assertEqual(ok, es_kernel_mgr_aggregate:stop(Pid)).

start_mgr(Timeout) ->
    StoreContext = es_kernel_app:get_store_context(),
    {ok, Pid} =
        es_kernel_mgr_aggregate:start_link(
            StoreContext,
            #{timeout => Timeout}
        ),
    Pid.
