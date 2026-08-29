-module(es_projection_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STORE, {es_store_ets, es_store_ets}).
-define(STREAM_A, {user, <<"account-A">>}).
-define(STREAM_B, {order, <<"order-B">>}).

suite_test_() ->
    Tests = [
        {"run_once_processes_global_log", fun run_once_processes_global_log/0},
        {"run_once_ignores_checkpoints", fun run_once_ignores_checkpoints/0},
        {"run_once_respects_start_position", fun run_once_respects_start_position/0},
        {"run_once_does_not_checkpoint_filtered_events",
            fun run_once_does_not_checkpoint_filtered_events/0},
        {"continuous_runner_requires_checkpoint_store",
            fun continuous_runner_requires_checkpoint_store/0},
        {"continuous_runner_rejects_invalid_checkpoint_store",
            fun continuous_runner_rejects_invalid_checkpoint_store/0},
        {"continuous_runner_stops_on_checkpoint_store_start_failure",
            fun continuous_runner_stops_on_checkpoint_store_start_failure/0},
        {"continuous_runner_stops_on_checkpoint_store_load_failure",
            fun continuous_runner_stops_on_checkpoint_store_load_failure/0},
        {"continuous_runner_stops_on_unknown_checkpoint_store",
            fun continuous_runner_stops_on_unknown_checkpoint_store/0},
        {"continuous_runner_uses_application_checkpoint_store",
            fun continuous_runner_uses_application_checkpoint_store/0},
        {"continuous_filtered_events_are_checkpointed",
            fun continuous_filtered_events_are_checkpointed/0},
        {"continuous_failure_does_not_advance_checkpoint",
            fun continuous_failure_does_not_advance_checkpoint/0},
        {"empty_tick_preserves_start_position", fun empty_tick_preserves_start_position/0},
        {"ets_checkpoint_owner_outlives_direct_runner",
            fun ets_checkpoint_owner_outlives_direct_runner/0},
        {"ets_checkpoint_owner_handles_control_messages",
            fun ets_checkpoint_owner_handles_control_messages/0},
        {"ets_checkpoint_start_link_adopts_existing_owner",
            fun ets_checkpoint_start_link_adopts_existing_owner/0},
        {"ets_checkpoint_stop_is_idempotent", fun ets_checkpoint_stop_is_idempotent/0},
        {"ets_checkpoint_start_reports_invalid_table_configuration",
            fun ets_checkpoint_start_reports_invalid_table_configuration/0},
        {"polling_processes_later_events", fun polling_processes_later_events/0},
        {"checkpoint_table_uses_projection_application_env",
            fun checkpoint_table_uses_projection_application_env/0},
        {"named_runner_can_be_stopped_by_name", fun named_runner_can_be_stopped_by_name/0}
    ],
    {foreach, fun setup/0, fun teardown/1, Tests}.

setup() ->
    ok = application:unset_env(es_projection, checkpoint_store),
    es_store_ets:start(),
    es_projection_checkpoint_ets:start(),
    ok.

teardown(_) ->
    es_store_ets:stop(),
    es_projection_checkpoint_ets:stop(),
    ok.

run_once_processes_global_log() ->
    [EventA1, EventB1, EventA2] = append_sample_events(),

    ?assertMatch(
        {ok, [{created, 0}, {ordered, 1}, {updated, 2}], 2},
        es_projection:run_once(?STORE, es_projection_collect, #{})
    ),
    ?assertEqual(
        {error, not_found},
        es_projection_checkpoint_ets:load_checkpoint(collect_projection)
    ),
    ?assertNot(maps:is_key(position, EventA1)),
    ?assertNot(maps:is_key(position, EventB1)),
    ?assertNot(maps:is_key(position, EventA2)).

run_once_ignores_checkpoints() ->
    append_sample_events(),
    ok = es_projection_checkpoint_ets:store_checkpoint(collect_projection, 0),

    ?assertMatch(
        {ok, [{created, 0}, {ordered, 1}, {updated, 2}], 2},
        es_projection:run_once(?STORE, es_projection_collect, #{})
    ),
    ?assertEqual(
        {ok, 0},
        es_projection_checkpoint_ets:load_checkpoint(collect_projection)
    ).

run_once_respects_start_position() ->
    append_sample_events(),

    ?assertMatch(
        {ok, [{ordered, 1}, {updated, 2}], 2},
        es_projection:run_once(
            ?STORE, es_projection_collect, #{start_position => 1}
        )
    ),
    ?assertEqual(
        {error, not_found},
        es_projection_checkpoint_ets:load_checkpoint(collect_projection)
    ).

run_once_does_not_checkpoint_filtered_events() ->
    append_sample_events(),

    ?assertMatch(
        {ok, [{created, 0}, {updated, 2}], 2},
        es_projection:run_once(?STORE, es_projection_filtered, #{})
    ),
    ?assertEqual(
        {error, not_found},
        es_projection_checkpoint_ets:load_checkpoint(filtered_projection)
    ).

continuous_runner_requires_checkpoint_store() ->
    Parent = self(),
    _Owner = spawn(fun() ->
        process_flag(trap_exit, true),
        Parent ! {startup_result, es_projection:start_link(?STORE, es_projection_collect, #{})}
    end),
    receive
        {startup_result, Result} ->
            ?assertEqual({error, checkpoint_store_not_configured}, Result)
    after 1000 ->
        ?assert(false)
    end.

continuous_runner_rejects_invalid_checkpoint_store() ->
    ?assertEqual(
        {error, invalid_checkpoint_store},
        start_link_result(#{checkpoint_store => 1})
    ).

continuous_runner_stops_on_checkpoint_store_start_failure() ->
    ?assertEqual(
        {error, checkpoint_start_failed},
        start_link_result(#{checkpoint_store => es_projection_checkpoint_start_failing})
    ).

continuous_runner_stops_on_checkpoint_store_load_failure() ->
    ?assertEqual(
        {error, checkpoint_load_failed},
        start_link_result(#{checkpoint_store => es_projection_checkpoint_load_failing})
    ).

continuous_runner_stops_on_unknown_checkpoint_store() ->
    ?assertMatch(
        {error, _},
        start_link_result(#{checkpoint_store => unknown_projection_checkpoint_store})
    ).

continuous_runner_uses_application_checkpoint_store() ->
    ok = application:set_env(es_projection, checkpoint_store, es_projection_checkpoint_ets),
    {ok, Pid} = es_projection:start_link(
        ?STORE, es_projection_collect, #{poll_interval => 20}
    ),
    try
        Timestamp = erlang:system_time(),
        Event = new_event(?STREAM_A, user, created, 1, Timestamp),
        ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_A, [Event])),
        wait_for_checkpoint(collect_projection, 0, 20)
    after
        es_projection:stop(Pid),
        ok = application:unset_env(es_projection, checkpoint_store)
    end.

continuous_filtered_events_are_checkpointed() ->
    append_sample_events(),
    {ok, Pid} = es_projection:start_link(
        ?STORE,
        es_projection_filtered,
        #{checkpoint_store => es_projection_checkpoint_ets, poll_interval => 20}
    ),
    try
        wait_for_checkpoint(filtered_projection, 2, 20)
    after
        es_projection:stop(Pid)
    end.

continuous_failure_does_not_advance_checkpoint() ->
    Timestamp = erlang:system_time(),
    EventOk = new_event(?STREAM_A, user, created, 1, Timestamp),
    EventFail = new_event(?STREAM_A, user, fail, 2, Timestamp),
    ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_A, [EventOk, EventFail])),
    Parent = self(),
    _Owner = spawn(fun() ->
        process_flag(trap_exit, true),
        {ok, Pid} = es_projection:start_link(
            ?STORE,
            es_projection_failing,
            #{checkpoint_store => es_projection_checkpoint_ets}
        ),
        receive
            {'EXIT', Pid, Reason} ->
                Parent ! {projection_exit, Reason}
        end
    end),
    receive
        {projection_exit, {handle_event_failed, 1, boom}} ->
            ok
    after 1000 ->
        ?assert(false)
    end,
    ?assertEqual(
        {ok, 0},
        es_projection_checkpoint_ets:load_checkpoint(failing_projection)
    ).

empty_tick_preserves_start_position() ->
    Timestamp = erlang:system_time(),
    InitialEvents = [
        new_event(?STREAM_A, user, created, 1, Timestamp),
        new_event(?STREAM_A, user, fail, 2, Timestamp)
    ],
    ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_A, InitialEvents)),
    ok = es_projection_checkpoint_ets:store_checkpoint(failing_projection, 0),
    {ok, Pid} = es_projection:start_link(
        ?STORE,
        es_projection_failing,
        #{
            checkpoint_store => es_projection_checkpoint_ets,
            start_position => 10,
            poll_interval => 20
        }
    ),
    try
        timer:sleep(50),
        LaterEvents = [
            new_event(?STREAM_A, user, created, Sequence, Timestamp)
         || Sequence <- lists:seq(3, 11)
        ],
        ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_A, LaterEvents)),
        wait_for_checkpoint(failing_projection, 10, 20),
        ?assert(is_process_alive(Pid))
    after
        case is_process_alive(Pid) of
            true ->
                es_projection:stop(Pid);
            false ->
                ok
        end
    end.

ets_checkpoint_owner_outlives_direct_runner() ->
    ok = es_projection_checkpoint_ets:stop(),
    {ok, Pid} = es_projection:start_link(
        ?STORE, es_projection_collect, #{checkpoint_store => es_projection_checkpoint_ets}
    ),
    try
        Owner = ets:info(projection_checkpoints, owner),
        ?assertNotEqual(Pid, Owner),
        ?assertEqual(Owner, erlang:whereis(es_projection_checkpoint_ets))
    after
        es_projection:stop(Pid)
    end,
    ?assertNotEqual(undefined, ets:info(projection_checkpoints)).

ets_checkpoint_owner_handles_control_messages() ->
    Owner = erlang:whereis(es_projection_checkpoint_ets),
    ?assertEqual(ok, gen_server:call(Owner, unexpected_call)),
    gen_server:cast(Owner, unexpected_cast),
    Owner ! unexpected_info,
    ?assertEqual(ok, gen_server:call(Owner, unexpected_call_after_messages)),
    ?assertEqual(
        {ok, #{}},
        es_projection_checkpoint_ets:code_change(undefined, #{}, undefined)
    ).

ets_checkpoint_start_link_adopts_existing_owner() ->
    Owner = erlang:whereis(es_projection_checkpoint_ets),
    try
        ?assertEqual({ok, Owner}, es_projection_checkpoint_ets:start_link())
    after
        erlang:unlink(Owner)
    end.

ets_checkpoint_stop_is_idempotent() ->
    ok = es_projection_checkpoint_ets:stop(),
    ?assertEqual(ok, es_projection_checkpoint_ets:stop()),
    {ok, Owner} = es_projection_checkpoint_ets:start_link(),
    try
        ?assertEqual(Owner, erlang:whereis(es_projection_checkpoint_ets))
    after
        erlang:unlink(Owner)
    end.

ets_checkpoint_start_reports_invalid_table_configuration() ->
    ok = es_projection_checkpoint_ets:stop(),
    ok = application:set_env(es_projection, projection_checkpoint_table_name, []),
    try
        ?assertMatch({error, _}, es_projection_checkpoint_ets:start())
    after
        ok = application:unset_env(es_projection, projection_checkpoint_table_name),
        ok = es_projection_checkpoint_ets:start()
    end.

polling_processes_later_events() ->
    {ok, Pid} = es_projection:start_link(
        ?STORE,
        es_projection_collect,
        #{checkpoint_store => es_projection_checkpoint_ets, poll_interval => 20}
    ),
    try
        Timestamp = erlang:system_time(),
        Event = new_event(?STREAM_A, user, created, 1, Timestamp),
        ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_A, [Event])),
        wait_for_checkpoint(collect_projection, 0, 20)
    after
        es_projection:stop(Pid)
    end.

named_runner_can_be_stopped_by_name() ->
    RunnerName = named_projection_runner,
    {ok, Pid} = es_projection:start_link(
        ?STORE,
        es_projection_collect,
        #{name => RunnerName, checkpoint_store => es_projection_checkpoint_ets, poll_interval => 20}
    ),
    try
        ?assertEqual(Pid, erlang:whereis(RunnerName)),
        ?assertEqual(ok, es_projection:stop(RunnerName)),
        ?assertEqual(undefined, erlang:whereis(RunnerName))
    after
        case erlang:whereis(RunnerName) of
            undefined ->
                ok;
            _ ->
                es_projection:stop(RunnerName)
        end
    end.

checkpoint_table_uses_projection_application_env() ->
    CustomTable = projection_checkpoints_test,
    ok = application:set_env(es_projection, projection_checkpoint_table_name, CustomTable),
    ok = es_projection_checkpoint_ets:start(),
    ?assertNotEqual(undefined, ets:info(CustomTable)),
    ok = es_projection_checkpoint_ets:stop(),
    ok = application:unset_env(es_projection, projection_checkpoint_table_name),
    ok = es_projection_checkpoint_ets:start().

append_sample_events() ->
    Timestamp = erlang:system_time(),
    EventA1 = new_event(?STREAM_A, user, created, 1, Timestamp),
    EventB1 = new_event(?STREAM_B, order, ordered, 1, Timestamp),
    EventA2 = new_event(?STREAM_A, user, updated, 2, Timestamp),
    ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_A, [EventA1])),
    ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_B, [EventB1])),
    ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_A, [EventA2])),
    [EventA1, EventB1, EventA2].

new_event(StreamId, AggregateType, Type, Sequence, Timestamp) ->
    es_kernel_store:new_event(StreamId, AggregateType, Type, Sequence, Timestamp, #{}).

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

start_link_result(Options) ->
    Parent = self(),
    _Owner = spawn(fun() ->
        process_flag(trap_exit, true),
        Parent ! {startup_result, es_projection:start_link(?STORE, es_projection_collect, Options)}
    end),
    receive
        {startup_result, Result} ->
            Result
    after 1000 ->
        ?assert(false)
    end.
