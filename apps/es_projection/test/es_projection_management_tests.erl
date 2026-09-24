-module(es_projection_management_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STORE, {es_store_ets, es_store_ets}).
-define(STREAM_A, {user, <<"account-A">>}).
-define(PROJECTION_PG_SCOPE, es_projection_pg).

suite_test_() ->
    Tests = [
        {"managed_runner_can_be_started_and_stopped",
            fun managed_runner_can_be_started_and_stopped/0},
        {"managed_runner_wakes_on_append", fun managed_runner_wakes_on_append/0},
        {"managed_runner_recovers_after_pg_restart",
            fun managed_runner_recovers_after_pg_restart/0},
        {"projection_scope_isolated_from_default_pg",
            fun projection_scope_isolated_from_default_pg/0},
        {"managed_runner_start_is_idempotent", fun managed_runner_start_is_idempotent/0},
        {"managed_runner_ignores_stale_subscription_messages",
            fun managed_runner_ignores_stale_subscription_messages/0},
        {"dead_runner_is_removed_from_registry", fun dead_runner_is_removed_from_registry/0}
    ],
    {foreach, fun setup/0, fun teardown/1, Tests}.

setup() ->
    es_store_ets:start(),
    {DefaultPg, OwnsDefaultPg} = ensure_default_pg(),
    {ok, _Started} = application:ensure_all_started(es_projection),
    {DefaultPg, OwnsDefaultPg}.

teardown({DefaultPg, OwnsDefaultPg}) ->
    _ = es_projection:stop(collect_projection),
    _ = es_projection:stop(failing_projection),
    application:stop(es_projection),
    es_store_ets:stop(),
    case OwnsDefaultPg andalso is_process_alive(DefaultPg) of
        true ->
            gen_server:stop(DefaultPg);
        false ->
            ok
    end,
    ok.

managed_runner_can_be_started_and_stopped() ->
    ?assertEqual({error, not_found}, es_projection:lookup(collect_projection)),

    {ok, Pid} = es_projection:start(
        ?STORE, es_projection_collect, #{
            checkpoint_store => es_projection_checkpoint_ets, poll_interval => 20
        }
    ),
    ?assertEqual({ok, Pid}, es_projection:lookup(collect_projection)),

    ?assertEqual(ok, es_projection:stop(collect_projection)),
    ?assertEqual({error, not_found}, es_projection:lookup(collect_projection)).

managed_runner_wakes_on_append() ->
    Timestamp = erlang:system_time(),
    FirstEvent = es_kernel_store:new_event(?STREAM_A, user, created, 1, Timestamp, #{}),
    SecondEvent = es_kernel_store:new_event(?STREAM_A, user, updated, 2, Timestamp, #{}),
    ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_A, [FirstEvent])),
    {ok, _Pid} = es_projection:start(
        ?STORE,
        es_projection_collect,
        #{checkpoint_store => es_projection_checkpoint_ets, poll_interval => 60000}
    ),
    try
        wait_for_checkpoint(collect_projection, 0, 20),
        ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_A, [SecondEvent])),
        wait_for_checkpoint(collect_projection, 1, 20)
    after
        es_projection:stop(collect_projection)
    end.

managed_runner_recovers_after_pg_restart() ->
    Timestamp = erlang:system_time(),
    FirstEvent = es_kernel_store:new_event(?STREAM_A, user, created, 1, Timestamp, #{}),
    SecondEvent = es_kernel_store:new_event(?STREAM_A, user, updated, 2, Timestamp, #{}),
    ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_A, [FirstEvent])),
    {ok, Pid} = es_projection:start(
        ?STORE,
        es_projection_collect,
        #{checkpoint_store => es_projection_checkpoint_ets, poll_interval => 60000}
    ),
    try
        wait_for_checkpoint(collect_projection, 0, 20),
        OldPg = erlang:whereis(?PROJECTION_PG_SCOPE),
        exit(OldPg, kill),
        wait_for_pg_restart(OldPg, 100),
        wait_for_pg_member(Pid, 100),
        ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_A, [SecondEvent])),
        wait_for_checkpoint(collect_projection, 1, 20)
    after
        es_projection:stop(Pid)
    end.

projection_scope_isolated_from_default_pg() ->
    ?assert(is_pid(erlang:whereis(pg))),
    ?assert(is_pid(erlang:whereis(?PROJECTION_PG_SCOPE))),
    ?assertNotEqual(erlang:whereis(pg), erlang:whereis(?PROJECTION_PG_SCOPE)).

managed_runner_start_is_idempotent() ->
    {ok, Pid} = es_projection:start(
        ?STORE, es_projection_collect, #{
            checkpoint_store => es_projection_checkpoint_ets, poll_interval => 20
        }
    ),
    ?assertEqual(
        {ok, Pid},
        es_projection:start(
            ?STORE,
            es_projection_collect,
            #{checkpoint_store => es_projection_checkpoint_ets, poll_interval => 20}
        )
    ),
    ?assertEqual(ok, es_projection:stop(collect_projection)).

managed_runner_ignores_stale_subscription_messages() ->
    {ok, Pid} = es_projection:start(
        ?STORE,
        es_projection_collect,
        #{checkpoint_store => es_projection_checkpoint_ets, poll_interval => 60000}
    ),
    try
        wait_for_pg_member(Pid, 20),
        Pid ! retry_pg_subscription,
        Pid ! unexpected_message,
        Timestamp = erlang:system_time(),
        Event = es_kernel_store:new_event(?STREAM_A, user, created, 1, Timestamp, #{}),
        ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_A, [Event])),
        wait_for_checkpoint(collect_projection, 0, 20)
    after
        es_projection:stop(Pid)
    end.

dead_runner_is_removed_from_registry() ->
    Timestamp = erlang:system_time(),
    Event = es_kernel_store:new_event(?STREAM_A, user, fail, 1, Timestamp, #{}),
    ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_A, [Event])),

    {ok, Pid} = es_projection:start(
        ?STORE, es_projection_failing, #{
            checkpoint_store => es_projection_checkpoint_ets, poll_interval => 20
        }
    ),
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

wait_for_checkpoint(_ProjectionName, _ExpectedPosition, 0) ->
    ?assert(false);
wait_for_checkpoint(ProjectionName, ExpectedPosition, AttemptsLeft) ->
    case es_projection_checkpoint_ets:load_checkpoint(ProjectionName) of
        {ok, ExpectedPosition} ->
            ok;
        _ ->
            timer:sleep(20),
            wait_for_checkpoint(ProjectionName, ExpectedPosition, AttemptsLeft - 1)
    end.

ensure_default_pg() ->
    case erlang:whereis(pg) of
        undefined ->
            case pg:start_link() of
                {ok, Pid} ->
                    unlink(Pid),
                    {Pid, true};
                {error, {already_started, Pid}} ->
                    {Pid, false}
            end;
        Pid ->
            {Pid, false}
    end.

wait_for_pg_restart(_OldPid, 0) ->
    ?assert(false);
wait_for_pg_restart(OldPid, AttemptsLeft) ->
    case erlang:whereis(?PROJECTION_PG_SCOPE) of
        NewPid when is_pid(NewPid), NewPid =/= OldPid ->
            ok;
        _ ->
            timer:sleep(10),
            wait_for_pg_restart(OldPid, AttemptsLeft - 1)
    end.

wait_for_pg_member(_Pid, 0) ->
    ?assert(false);
wait_for_pg_member(Pid, AttemptsLeft) ->
    Members = pg:get_members(?PROJECTION_PG_SCOPE, {es_projection_wakeup, ?STORE}),
    case lists:member(Pid, Members) of
        true ->
            ok;
        false ->
            timer:sleep(10),
            wait_for_pg_member(Pid, AttemptsLeft - 1)
    end.
