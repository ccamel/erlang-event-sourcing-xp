-module(es_kernel_mgr_aggregate_tests).

-include_lib("eunit/include/eunit.hrl").

suite_test_() ->
    TestCases =
        [
            {"aggregate_behaviour", fun aggregate_behaviour/0},
            {"aggregate_dispatch_isolation", fun aggregate_dispatch_isolation/0},
            {"aggregate_passivation", fun aggregate_passivation/0},
            {"aggregate_invalid_command", fun aggregate_invalid_command/0},
            {"aggregate_survives_dead_worker", fun aggregate_survives_dead_worker/0}
        ],
    {foreach, fun setup/0, fun teardown/1, TestCases}.

setup() ->
    %% Set test configuration before starting the application
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

agg_id(AggregateType, Id) ->
    ChildId = {es_kernel_aggregate, AggregateType, Id},
    {ChildId, AggPid, worker, _} =
        lists:keyfind(ChildId, 1, supervisor:which_children(es_kernel_aggregate_sup)),
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
        {state, bank_account, #{runtime := erlang, module := bank_account_aggregate}, StoreCtx, Id,
            ExpectedState, ExpectedSeq, _, _, _, _, _},
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
    ?assertState(agg_id(bank_account, Id), Id, #{balance := 100}, 1),

    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, cmd(deposit, Id, #{amount => 100}))
    ),
    ?assertState(agg_id(bank_account, Id), Id, #{balance := 200}, 2),

    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, cmd(withdraw, Id, #{amount => 50}))
    ),
    ?assertState(agg_id(bank_account, Id), Id, #{balance := 150}, 3),

    ?assertEqual(ok, es_kernel_mgr_aggregate:stop(Pid)).

aggregate_dispatch_isolation() ->
    Pid = start_mgr(5000),
    A = <<"a">>,
    B = <<"b">>,
    ok = es_kernel:dispatch(cmd(deposit, A, #{amount => 10})),
    ok = es_kernel:dispatch(cmd(deposit, B, #{amount => 10})),
    AggPid = agg_id(bank_account, A),
    ok = sys:suspend(AggPid),
    {Deposit, Withdraw} =
        try
            %% Send all three calls from one process so the router sees them in order.
            DepositReq = gen_server:send_request(Pid, cmd(deposit, A, #{amount => 50})),
            WithdrawReq = gen_server:send_request(Pid, cmd(withdraw, A, #{amount => 60})),
            ?assertEqual(ok, gen_server:call(Pid, cmd(deposit, B, #{amount => 20}), 1000)),
            {DepositReq, WithdrawReq}
        after
            ok = sys:resume(AggPid)
        end,
    ?assertEqual({reply, ok}, gen_server:receive_response(Deposit, 1000)),
    ?assertEqual({reply, ok}, gen_server:receive_response(Withdraw, 1000)),
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

    AggPid = agg_id(bank_account, Id),
    ?assertState(AggPid, Id, #{balance := 75}, 2),

    % wait for the aggregate to be passivated
    timer:sleep(2000),

    ?assertNot(is_process_alive(AggPid)),

    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, cmd(deposit, Id, #{amount => 30}))
    ),

    ?assertState(agg_id(bank_account, Id), Id, #{balance := 105}, 3),

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

aggregate_survives_dead_worker() ->
    Pid = start_mgr(5000),
    Id = <<"123">>,

    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, cmd(deposit, Id, #{amount => 100}))
    ),
    AggPid = agg_id(bank_account, Id),
    ok = sys:suspend(AggPid),
    Command = cmd(deposit, Id, #{amount => 10}),
    Req = gen_server:send_request(Pid, Command),
    %% The manager has forwarded the request before handling this system call.
    _ = sys:get_state(Pid, 1000),
    exit(AggPid, kill),
    CallExit = {killed, {gen_server, call, [AggPid, Command, infinity]}},
    ?assertEqual(
        {reply, {error, {aggregate_down, CallExit}}},
        gen_server:receive_response(Req, 1000)
    ),

    %% Next dispatch should start a fresh aggregate and succeed (rehydrated to previous balance)
    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, cmd(deposit, Id, #{amount => 20}))
    ),
    ?assertState(agg_id(bank_account, Id), Id, #{balance := 120}, 2),

    ?assertEqual(ok, es_kernel_mgr_aggregate:stop(Pid)).

start_mgr(Timeout) ->
    StoreContext = es_kernel_app:get_store_context(),
    {ok, Pid} =
        es_kernel_mgr_aggregate:start_link(
            StoreContext,
            #{timeout => Timeout}
        ),
    Pid.
