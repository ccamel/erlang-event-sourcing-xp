-module(event_sourcing_core_store_snapshot_stub_tests).

-include_lib("eunit/include/eunit.hrl").

suite_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        {"concurrent_start_operations", fun concurrent_start_operations/0},
        {"concurrent_stop_operations", fun concurrent_stop_operations/0},
        {"concurrent_start_stop_operations", fun concurrent_start_stop_operations/0}
    ]}.

setup() ->
    event_sourcing_core_store_snapshot_stub:stop(),
    ok.

teardown(_) ->
    event_sourcing_core_store_snapshot_stub:stop(),
    ok.

concurrent_start_operations() ->
    NumProcesses = 10,
    Self = self(),

    Pids = [
        spawn(fun() ->
            Result = event_sourcing_core_store_snapshot_stub:start(),
            Self ! {start_result, self(), Result}
        end)
     || _ <- lists:seq(1, NumProcesses)
    ],

    Results = [
        receive
            {start_result, _Pid, Result} -> Result
        after 5000 ->
            timeout
        end
     || _ <- Pids
    ],

    ?assertEqual(NumProcesses, length([ok || ok <- Results])),
    ?assertEqual(ok, event_sourcing_core_store_snapshot_stub:stop()).

concurrent_stop_operations() ->
    ?assertMatch(ok, event_sourcing_core_store_snapshot_stub:start()),

    NumProcesses = 10,
    Self = self(),

    Pids = [
        spawn(fun() ->
            Result = event_sourcing_core_store_snapshot_stub:stop(),
            Self ! {stop_result, self(), Result}
        end)
     || _ <- lists:seq(1, NumProcesses)
    ],

    Results = [
        receive
            {stop_result, _Pid, Result} -> Result
        after 5000 ->
            timeout
        end
     || _ <- Pids
    ],

    ?assertEqual(NumProcesses, length([ok || ok <- Results])).

concurrent_start_stop_operations() ->
    NumProcesses = 20,
    Self = self(),

    Pids = [
        spawn(fun() ->
            case N rem 2 of
                0 ->
                    Result = event_sourcing_core_store_snapshot_stub:start(),
                    Self ! {result, self(), start, Result};
                1 ->
                    Result = event_sourcing_core_store_snapshot_stub:stop(),
                    Self ! {result, self(), stop, Result}
            end
        end)
     || N <- lists:seq(1, NumProcesses)
    ],

    Results = [
        receive
            {result, _Pid, _Op, Result} -> Result
        after 5000 ->
            timeout
        end
     || _ <- Pids
    ],

    ?assertEqual(NumProcesses, length([ok || ok <- Results])),
    event_sourcing_core_store_snapshot_stub:stop().
