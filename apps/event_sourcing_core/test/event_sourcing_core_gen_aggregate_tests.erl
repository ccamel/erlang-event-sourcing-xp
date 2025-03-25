-module(event_sourcing_core_gen_aggregate_tests).

-include_lib("eunit/include/eunit.hrl").

suite_test_() ->
    TestCases =
        [{"aggregate_behaviour", fun aggregate_behaviour/0},
         {"aggregate_passivation", fun aggregate_passivation/0},
         {"aggregate_invalid_command", fun aggregate_invalid_command/0}],
    {foreach, fun setup/0, fun teardown/1, TestCases}.

setup() ->
    event_sourcing_store:start(event_sourcing_store_ets),
    ok.

teardown(_) ->
    event_sourcing_store:stop(event_sourcing_store_ets),
    ok.

%%%  Test cases

-define(assertState(Pid, Id, ExpectedState, ExpectedSeq),
        ?assertMatch({state,
                      bank_account_aggregate,
                      event_sourcing_store_ets,
                      Id,
                      ExpectedState,
                      ExpectedSeq,
                      _,
                      _,
                      _,
                      _,
                      _},
                     sys:get_state(Pid))).

aggregate_behaviour() ->
    {Id, Pid} = start_test_account(5000),

    ?assertState(Pid, Id, #{balance := 0}, 0),

    ?assertEqual(ok, event_sourcing_core_gen_aggregate:dispatch(Pid, {deposit, 100})),
    ?assertState(Pid, Id, #{balance := 100}, 1),

    ?assertEqual(ok, event_sourcing_core_gen_aggregate:dispatch(Pid, {deposit, 100})),
    ?assertState(Pid, Id, #{balance := 200}, 2),

    ?assertEqual(ok, event_sourcing_core_gen_aggregate:dispatch(Pid, {withdraw, 50})),
    ?assertState(Pid, Id, #{balance := 150}, 3).

aggregate_passivation() ->
    {Id, Pid} = start_test_account(1000),

    ?assertEqual(ok, event_sourcing_core_gen_aggregate:dispatch(Pid, {deposit, 100})),
    ?assertEqual(ok, event_sourcing_core_gen_aggregate:dispatch(Pid, {withdraw, 25})),

    ?assertState(Pid, Id, #{balance := 75}, 2),

    % wait for the aggregate to be passivated
    timer:sleep(2000),

    % check pid is not alive
    ?assertEqual(false, is_process_alive(Pid)),

    % start a new aggregate with the same id and check hydration
    {_, Pid2} = start_test_account(5000),
    ?assertState(Pid2, Id, #{balance := 75}, 2).

aggregate_invalid_command() ->
    {_, Pid} = start_test_account(5000),

    ?assertEqual({error, invalid_command},
                 event_sourcing_core_gen_aggregate:dispatch(Pid, invalid)),
    ?assertEqual({error, insufficient_funds},
                 event_sourcing_core_gen_aggregate:dispatch(Pid, {withdraw, 100})).

start_test_account(Timeout) ->
    Id = <<"bank-account-123">>,
    {ok, Pid} =
        event_sourcing_core_gen_aggregate:start_link(bank_account_aggregate,
                                                     event_sourcing_store_ets,
                                                     Id,
                                                     #{timeout => Timeout}),
    {Id, Pid}.
