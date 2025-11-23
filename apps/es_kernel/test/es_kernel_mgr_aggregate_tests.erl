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

    StoreContext = es_kernel_app:get_store_context(),
    es_kernel_store:start(StoreContext),

    %% Start the aggregate supervisor needed by the manager
    case whereis(es_kernel_aggregate_sup) of
        undefined ->
            {ok, _Pid} = es_kernel_aggregate_sup:start_link();
        _Pid ->
            ok
    end,
    StoreContext.

teardown(StoreContext) ->
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
    es_kernel_store:stop(StoreContext).

%%%  Test cases

agg_id(Pid, Id) ->
    {state, _, _, _, _, #{Id := AggPid}} = sys:get_state(Pid),
    AggPid.

-define(assertState(Pid, Id, ExpectedState, ExpectedSeq), begin
    StoreCtx = es_kernel_app:get_store_context(),
    ?assertMatch(
        {state, bank_account_aggregate, StoreCtx, Id, ExpectedState, ExpectedSeq, _, _, _, _},
        sys:get_state(Pid)
    )
end).

aggregate_behaviour() ->
    Pid = start_mgr(5000),
    Id = <<"bank-account-123">>,

    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, {bank, deposit, Id, 100})
    ),
    ?assertState(agg_id(Pid, Id), Id, #{balance := 100}, 1),

    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, {bank, deposit, Id, 100})
    ),
    ?assertState(agg_id(Pid, Id), Id, #{balance := 200}, 2),

    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, {bank, withdraw, Id, 50})
    ),
    ?assertState(agg_id(Pid, Id), Id, #{balance := 150}, 3),

    ?assertEqual(ok, es_kernel_mgr_aggregate:stop(Pid)).

aggregate_passivation() ->
    Pid = start_mgr(1000),
    Id = <<"bank-account-123">>,

    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, {bank, deposit, Id, 100})
    ),
    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, {bank, withdraw, Id, 25})
    ),

    ?assertState(agg_id(Pid, Id), Id, #{balance := 75}, 2),

    % wait for the aggregate to be passivated
    timer:sleep(2000),

    % check aggregate is no more alive
    {_, _, _, _, _, AggPids} = sys:get_state(Pid),
    ?assertEqual(false, maps:is_key(Id, AggPids)),

    ?assertEqual(
        ok,
        es_kernel_mgr_aggregate:dispatch(Pid, {bank, deposit, Id, 30})
    ),

    ?assertState(agg_id(Pid, Id), Id, #{balance := 105}, 3),

    ?assertEqual(ok, es_kernel_mgr_aggregate:stop(Pid)).

aggregate_invalid_command() ->
    Pid = start_mgr(5000),
    Id = <<"bank-account-123">>,

    ?assertEqual(
        {error, invalid_command},
        es_kernel_mgr_aggregate:dispatch(Pid, invalid)
    ),
    ?assertEqual(
        {error, insufficient_funds},
        es_kernel_mgr_aggregate:dispatch(Pid, {bank, withdraw, Id, 100})
    ),

    ?assertEqual(ok, es_kernel_mgr_aggregate:stop(Pid)).

start_mgr(Timeout) ->
    StoreContext = es_kernel_app:get_store_context(),
    {ok, Pid} =
        es_kernel_mgr_aggregate:start_link(
            bank_account_aggregate,
            StoreContext,
            bank_account_aggregate,
            #{timeout => Timeout}
        ),
    Pid.
