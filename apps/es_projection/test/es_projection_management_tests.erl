-module(es_projection_management_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STORE, {es_store_ets, es_store_ets}).
-define(STREAM_A, {user, <<"account-A">>}).

suite_test_() ->
    Tests = [
        {"managed_runner_can_be_started_and_stopped",
            fun managed_runner_can_be_started_and_stopped/0},
        {"managed_runner_start_is_idempotent", fun managed_runner_start_is_idempotent/0},
        {"dead_runner_is_removed_from_registry", fun dead_runner_is_removed_from_registry/0}
    ],
    {foreach, fun setup/0, fun teardown/1, Tests}.

setup() ->
    es_store_ets:start(),
    {ok, _Started} = application:ensure_all_started(es_projection),
    ok.

teardown(_) ->
    _ = es_projection:stop(collect_projection),
    _ = es_projection:stop(failing_projection),
    application:stop(es_projection),
    es_store_ets:stop(),
    ok.

managed_runner_can_be_started_and_stopped() ->
    ?assertEqual({error, not_found}, es_projection:lookup(collect_projection)),

    {ok, Pid} = es_projection:start(?STORE, es_projection_collect, #{poll_interval => 20}),
    ?assertEqual({ok, Pid}, es_projection:lookup(collect_projection)),

    ?assertEqual(ok, es_projection:stop(collect_projection)),
    ?assertEqual({error, not_found}, es_projection:lookup(collect_projection)).

managed_runner_start_is_idempotent() ->
    {ok, Pid} = es_projection:start(?STORE, es_projection_collect, #{poll_interval => 20}),
    ?assertEqual(
        {ok, Pid},
        es_projection:start(?STORE, es_projection_collect, #{poll_interval => 20})
    ),
    ?assertEqual(ok, es_projection:stop(collect_projection)).

dead_runner_is_removed_from_registry() ->
    Timestamp = erlang:system_time(),
    Event = es_kernel_store:new_event(?STREAM_A, user, fail, 1, Timestamp, #{}),
    ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_A, [Event])),

    {ok, Pid} = es_projection:start(?STORE, es_projection_failing, #{poll_interval => 20}),
    ?assertEqual({ok, Pid}, es_projection:lookup(failing_projection)),
    wait_until_removed(failing_projection, 20).

wait_until_removed(_ProjectionName, 0) ->
    ?assert(false);
wait_until_removed(ProjectionName, AttemptsLeft) ->
    case es_projection:lookup(ProjectionName) of
        {error, not_found} ->
            ok;
        {ok, _Pid} ->
            timer:sleep(20),
            wait_until_removed(ProjectionName, AttemptsLeft - 1)
    end.
