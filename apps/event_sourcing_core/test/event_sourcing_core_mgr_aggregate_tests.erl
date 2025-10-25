-module(event_sourcing_core_mgr_aggregate_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ETS_STORE, {event_sourcing_store_ets, event_sourcing_store_ets}).

suite_test_() ->
    TestCases =
        [
            {"aggregate_behaviour", fun aggregate_behaviour/0},
            {"aggregate_passivation", fun aggregate_passivation/0},
            {"aggregate_invalid_command", fun aggregate_invalid_command/0}
        ],
    {foreach, fun setup/0, fun teardown/1, TestCases}.

setup() ->
    event_sourcing_core_store:start(?ETS_STORE).

teardown(_) ->
    event_sourcing_core_store:stop(?ETS_STORE).

%%%  Test cases

agg_id(Pid, Id) ->
    {state, _, _, _, _, #{Id := AggPid}} = sys:get_state(Pid),
    AggPid.

-define(assertState(Pid, Id, ExpectedState, ExpectedSeq),
    ?assertMatch(
        {state, bank_account_aggregate, ?ETS_STORE, Id, ExpectedState, ExpectedSeq, _, _, _, _, _,
            _},
        sys:get_state(Pid)
    )
).

aggregate_behaviour() ->
    Pid = start_mgr(5000),
    Id = <<"bank-account-123">>,

    ?assertEqual(
        ok,
        event_sourcing_core_mgr_aggregate:dispatch(Pid, {bank, deposit, Id, 100})
    ),
    ?assertState(agg_id(Pid, Id), Id, #{balance := 100}, 1),

    ?assertEqual(
        ok,
        event_sourcing_core_mgr_aggregate:dispatch(Pid, {bank, deposit, Id, 100})
    ),
    ?assertState(agg_id(Pid, Id), Id, #{balance := 200}, 2),

    ?assertEqual(
        ok,
        event_sourcing_core_mgr_aggregate:dispatch(Pid, {bank, withdraw, Id, 50})
    ),
    ?assertState(agg_id(Pid, Id), Id, #{balance := 150}, 3),

    ?assertEqual(ok, event_sourcing_core_mgr_aggregate:stop(Pid)).

aggregate_passivation() ->
    Pid = start_mgr(1000),
    Id = <<"bank-account-123">>,

    ?assertEqual(
        ok,
        event_sourcing_core_mgr_aggregate:dispatch(Pid, {bank, deposit, Id, 100})
    ),
    ?assertEqual(
        ok,
        event_sourcing_core_mgr_aggregate:dispatch(Pid, {bank, withdraw, Id, 25})
    ),

    ?assertState(agg_id(Pid, Id), Id, #{balance := 75}, 2),

    % wait for the aggregate to be passivated
    timer:sleep(2000),

    % check aggregate is no more alive
    {_, _, _, _, _, AggPids} = sys:get_state(Pid),
    ?assertEqual(false, maps:is_key(Id, AggPids)),

    ?assertEqual(
        ok,
        event_sourcing_core_mgr_aggregate:dispatch(Pid, {bank, deposit, Id, 30})
    ),

    ?assertState(agg_id(Pid, Id), Id, #{balance := 105}, 3),

    ?assertEqual(ok, event_sourcing_core_mgr_aggregate:stop(Pid)).

aggregate_invalid_command() ->
    Pid = start_mgr(5000),
    Id = <<"bank-account-123">>,

    ?assertEqual(
        {error, invalid_command},
        event_sourcing_core_mgr_aggregate:dispatch(Pid, invalid)
    ),
    ?assertEqual(
        {error, insufficient_funds},
        event_sourcing_core_mgr_aggregate:dispatch(Pid, {bank, withdraw, Id, 100})
    ),

    ?assertEqual(ok, event_sourcing_core_mgr_aggregate:stop(Pid)).

start_mgr(Timeout) ->
    {ok, Pid} =
        event_sourcing_core_mgr_aggregate:start_link(
            bank_account_aggregate,
            ?ETS_STORE,
            bank_account_aggregate,
            #{timeout => Timeout}
        ),
    Pid.
