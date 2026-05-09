-module(es_projection_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STORE, {es_store_ets, es_store_ets}).
-define(STREAM_A, {user, <<"account-A">>}).
-define(STREAM_B, {order, <<"order-B">>}).

suite_test_() ->
    Tests = [
        {"run_once_processes_global_log", fun run_once_processes_global_log/0},
        {"run_once_resumes_from_checkpoint", fun run_once_resumes_from_checkpoint/0},
        {"run_once_respects_start_position", fun run_once_respects_start_position/0},
        {"filtered_events_are_checkpointed", fun filtered_events_are_checkpointed/0},
        {"failed_event_is_not_checkpointed", fun failed_event_is_not_checkpointed/0},
        {"polling_processes_later_events", fun polling_processes_later_events/0},
        {"named_runner_can_be_stopped_by_name", fun named_runner_can_be_stopped_by_name/0}
    ],
    {foreach, fun setup/0, fun teardown/1, Tests}.

setup() ->
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
        {ok, [created, ordered, updated], 2},
        es_projection:run_once(?STORE, es_projection_collect, #{})
    ),
    ?assertEqual(
        {ok, 2},
        es_projection_checkpoint_ets:load_checkpoint(collect_projection)
    ),
    ?assertNot(maps:is_key(position, EventA1)),
    ?assertNot(maps:is_key(position, EventB1)),
    ?assertNot(maps:is_key(position, EventA2)).

run_once_resumes_from_checkpoint() ->
    append_sample_events(),
    ok = es_projection_checkpoint_ets:store_checkpoint(collect_projection, 0),

    ?assertMatch(
        {ok, [ordered, updated], 2},
        es_projection:run_once(?STORE, es_projection_collect, #{})
    ),
    ?assertEqual(
        {ok, 2},
        es_projection_checkpoint_ets:load_checkpoint(collect_projection)
    ).

run_once_respects_start_position() ->
    append_sample_events(),

    ?assertMatch(
        {ok, [ordered, updated], 2},
        es_projection:run_once(
            ?STORE, es_projection_collect, #{start_position => 1}
        )
    ),
    ?assertEqual(
        {ok, 2},
        es_projection_checkpoint_ets:load_checkpoint(collect_projection)
    ).

filtered_events_are_checkpointed() ->
    append_sample_events(),

    ?assertMatch(
        {ok, [created, updated], 2},
        es_projection:run_once(?STORE, es_projection_filtered, #{})
    ),
    ?assertEqual(
        {ok, 2},
        es_projection_checkpoint_ets:load_checkpoint(filtered_projection)
    ).

failed_event_is_not_checkpointed() ->
    Timestamp = erlang:system_time(),
    EventOk = new_event(?STREAM_A, user, created, 1, Timestamp),
    EventFail = new_event(?STREAM_A, user, fail, 2, Timestamp),
    ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM_A, [EventOk, EventFail])),

    ?assertEqual(
        {error, {handle_event_failed, 1, boom}},
        es_projection:run_once(?STORE, es_projection_failing, #{})
    ),
    ?assertEqual(
        {ok, 0},
        es_projection_checkpoint_ets:load_checkpoint(failing_projection)
    ).

polling_processes_later_events() ->
    {ok, Pid} = es_projection:start_link(
        ?STORE, es_projection_collect, #{poll_interval => 20}
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
        ?STORE, es_projection_collect, #{name => RunnerName, poll_interval => 20}
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
