-module(es_kernel_wasm_qjs_tests).

-include_lib("eunit/include/eunit.hrl").

-define(QJS_URL,
    "https://github.com/second-state/wasmedge-quickjs/releases/download/v0.5.0-alpha/wasmedge_quickjs.wasm"
).
-define(QJS_SHA256, <<"b8451261a244b7bc62ae95acb43882044aed2f3d5f08355889252b418ec89231">>).
-define(NORMAL_TYPE, wasm_test_campaign).
-define(TIMEOUT_TYPE, wasm_test_timeout_campaign).

suite_test_() ->
    TestCases = [
        {"WASM decides and persists events", fun wasm_decision/0},
        {"WASM refusal persists nothing", fun wasm_refusal/0},
        {"WASM aggregate replays events", fun wasm_replay/0},
        {"WASM aggregate rehydrates snapshots", fun wasm_snapshot_rehydration/0},
        {"WASM execution failure persists nothing", fun wasm_execution_failure/0},
        {"WASM worker dies with caller", fun wasm_worker_lifecycle/0},
        {"WASM timeout crosses API boundary", {timeout, 10, fun wasm_timeout_api/0}},
        {"WASM JSON preserves __proto__", fun wasm_proto_key/0},
        {"WASM registry rejects conflicting descriptors", fun wasm_registry_conflict/0},
        {"WASM bridge enforces runtime limits", fun wasm_bridge_limits/0},
        {"WASM bridge handles WASI exit codes", fun wasm_guest_exit_codes/0},
        {"WASM bridge encodes JSON value shapes", fun wasm_json_term_shapes/0},
        {"WASM bridge rejects unsupported JSON", fun wasm_json_term_rejections/0},
        {"WASM bridge reports load and output failures", fun wasm_bridge_failures/0},
        {"WASM domain rejects invalid guest contracts", fun wasm_domain_invalid_results/0},
        {"WASM domain wraps guest execution failures", fun wasm_domain_execution_failures/0}
    ],
    {foreach, fun setup/0, fun teardown/1, TestCases}.

setup() ->
    application:load(es_kernel),
    application:set_env(es_kernel, event_store, es_store_ets),
    application:set_env(es_kernel, snapshot_store, es_store_ets),
    application:set_env(es_kernel, snapshot_interval, 0),
    {ok, _} = application:ensure_all_started(wasm),
    QjsModule = ensure_qjs(),
    SourcePath = fixture_path("campaign.js"),
    ok = filelib:ensure_dir(SourcePath),
    ok = file:write_file(SourcePath, fixture_source()),
    ScratchDir = fixture_path("scratch"),
    _ = file:del_dir_r(ScratchDir),
    application:set_env(es_kernel, wasm_scratch_dir, ScratchDir),
    register_domains(QjsModule, SourcePath),
    StoreContext = es_kernel_app:get_store_context(),
    {EventStore, SnapshotStore} = StoreContext,
    EventStore:start(),
    case SnapshotStore =:= EventStore of
        true -> ok;
        false -> SnapshotStore:start()
    end,
    start_aggregate_supervisor(),
    start_manager(StoreContext),
    StoreContext.

teardown({EventStore, SnapshotStore}) ->
    stop_manager(),
    stop_aggregate_supervisor(),
    case SnapshotStore =:= EventStore of
        true ->
            EventStore:stop();
        false ->
            SnapshotStore:stop(),
            EventStore:stop()
    end,
    _ = file:del_dir_r(fixture_path("scratch")),
    _ = file:delete(fixture_path("invalid-json.js")),
    _ = file:delete(fixture_path("invalid-domain.js")),
    _ = file:delete(fixture_path("failing-domain.js")),
    _ = file:delete(fixture_path("exit-zero.js")),
    _ = file:delete(fixture_path("exit-error.js")),
    ok.

wasm_decision() ->
    Id = aggregate_id(),
    {ok, Pid} = start_aggregate(?NORMAL_TYPE, Id, #{}),
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid, command(?NORMAL_TYPE, open, Id))),
    [Event] = events(?NORMAL_TYPE, Id),
    ?assertEqual(<<"opened">>, maps:get(type, Event)),
    ?assertEqual(#{<<"type">> => <<"opened">>}, maps:get(payload, Event)).

wasm_refusal() ->
    Id = aggregate_id(),
    {ok, Pid} = start_aggregate(?NORMAL_TYPE, Id, #{}),
    ?assertEqual(
        {error, <<"rejected">>}, es_kernel_aggregate:execute(Pid, command(?NORMAL_TYPE, reject, Id))
    ),
    ?assertEqual([], events(?NORMAL_TYPE, Id)).

wasm_replay() ->
    Id = aggregate_id(),
    {ok, Pid1} = start_aggregate(?NORMAL_TYPE, Id, #{}),
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid1, command(?NORMAL_TYPE, open, Id))),
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid1, command(?NORMAL_TYPE, claim, Id))),
    ok = gen_server:stop(Pid1),
    {ok, Pid2} = start_aggregate(?NORMAL_TYPE, Id, #{}),
    ?assertEqual(
        {error, <<"already_claimed">>},
        es_kernel_aggregate:execute(Pid2, command(?NORMAL_TYPE, claim, Id))
    ).

wasm_snapshot_rehydration() ->
    Id = aggregate_id(),
    {ok, Pid1} = start_aggregate(?NORMAL_TYPE, Id, #{snapshot_interval => 1}),
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid1, command(?NORMAL_TYPE, open, Id))),
    {ok, Snapshot} = es_kernel_store:load_latest(
        es_kernel_app:get_store_context(), {?NORMAL_TYPE, Id}
    ),
    ?assertEqual(1, maps:get(sequence, Snapshot)),
    ?assertEqual(#{<<"claimed">> => false, <<"status">> => <<"open">>}, maps:get(state, Snapshot)),
    ok = gen_server:stop(Pid1),
    {ok, Pid2} = start_aggregate(?NORMAL_TYPE, Id, #{}),
    ?assertEqual(ok, es_kernel_aggregate:execute(Pid2, command(?NORMAL_TYPE, claim, Id))).

wasm_execution_failure() ->
    Id = aggregate_id(),
    {ok, Pid} = start_aggregate(?NORMAL_TYPE, Id, #{}),
    ?assertMatch(
        {error, {domain_execution_failed, _}},
        es_kernel_aggregate:execute(Pid, command(?NORMAL_TYPE, crash, Id))
    ),
    ?assertEqual([], events(?NORMAL_TYPE, Id)).

wasm_worker_lifecycle() ->
    SourcePath = fixture_path("campaign.js"),
    ScratchDir = fixture_path("scratch"),
    Domain = #{
        runtime => wasm,
        engine => quickjs,
        module => ensure_qjs(),
        source => SourcePath,
        timeout => 60000
    },
    Caller = spawn(fun() -> es_kernel_wasm_qjs:invoke(Domain, #{<<"op">> => <<"loop">>}) end),
    wait_for_children(ScratchDir, 100),
    exit(Caller, kill),
    wait_for_empty_directory(ScratchDir, 100).

wasm_timeout_api() ->
    Id = aggregate_id(),
    Started = erlang:monotonic_time(millisecond),
    ?assertEqual(
        {error, {domain_execution_failed, timeout}},
        es_kernel:dispatch(command(?TIMEOUT_TYPE, slow, Id))
    ),
    ?assert(erlang:monotonic_time(millisecond) - Started >= 6000).

wasm_proto_key() ->
    Domain = #{
        runtime => wasm,
        engine => quickjs,
        module => ensure_qjs(),
        source => fixture_path("campaign.js")
    },
    ?assertMatch(
        {ok, #{<<"__proto__">> := #{<<"value">> := 42}}},
        es_kernel_wasm_qjs:invoke(
            Domain,
            #{<<"op">> => <<"echo">>, <<"__proto__">> => #{<<"value">> => 42}}
        )
    ).

wasm_registry_conflict() ->
    Domain = domain(ensure_qjs(), fixture_path("campaign.js"), 5001),
    ?assertMatch(
        {already_registered, {?NORMAL_TYPE, _}},
        (try
            es_kernel_registry:register(?NORMAL_TYPE, Domain)
        catch
            error:Reason -> Reason
        end)
    ).

wasm_bridge_limits() ->
    Domain = domain(ensure_qjs(), fixture_path("campaign.js"), 5000),
    ?assertMatch(
        {error, {instantiate_failed, _}},
        es_kernel_wasm_qjs:invoke(Domain#{limits => #{fuel => 0}}, #{<<"op">> => <<"echo">>})
    ),
    ?assertMatch(
        {error, {worker_crashed, _}},
        es_kernel_wasm_qjs:invoke(
            Domain#{limits => #{max_heap_words => not_an_integer}},
            #{<<"op">> => <<"echo">>}
        )
    ),
    ?assertMatch(
        {ok, #{<<"op">> := <<"echo">>}},
        es_kernel_wasm_qjs:invoke(
            Domain#{limits => #{max_heap_words => 16_777_216}},
            #{<<"op">> => <<"echo">>}
        )
    ).

wasm_guest_exit_codes() ->
    ZeroExitDomain = source_domain(
        "exit-zero.js",
        <<
            "import * as std from 'std';\n"
            "function main(_input) { std.out.puts('{\"state\":{}}'); std.exit(0); }\n"
        >>
    ),
    ?assertEqual(
        {ok, #{<<"state">> => #{}}},
        es_kernel_wasm_qjs:invoke(ZeroExitDomain, #{<<"op">> => <<"init">>})
    ),
    ErrorExitDomain = source_domain(
        "exit-error.js",
        <<"import * as std from 'std';\nfunction main(_input) { std.exit(13); }\n">>
    ),
    ?assertMatch(
        {error, {guest_exit, 13, _}},
        es_kernel_wasm_qjs:invoke(ErrorExitDomain, #{<<"op">> => <<"init">>})
    ).

wasm_json_term_shapes() ->
    Domain = domain(ensure_qjs(), fixture_path("campaign.js"), 5000),
    Input = #{
        atom_key => [true, false, null, {1, <<"two">>}],
        7 => available,
        <<"op">> => <<"echo">>
    },
    ?assertEqual(
        {ok, #{
            <<"atom_key">> => [true, false, null, [1, <<"two">>]],
            <<"7">> => <<"available">>,
            <<"op">> => <<"echo">>
        }},
        es_kernel_wasm_qjs:invoke(Domain, Input)
    ).

wasm_json_term_rejections() ->
    Domain = domain(ensure_qjs(), fixture_path("campaign.js"), 5000),
    Pid = self(),
    ?assertError(
        {unsupported_json_term, Pid},
        es_kernel_wasm_qjs:invoke(Domain, #{<<"op">> => <<"echo">>, <<"bad">> => Pid})
    ),
    ?assertError(
        {unsupported_json_key, Pid},
        es_kernel_wasm_qjs:invoke(Domain, #{Pid => <<"bad key">>})
    ).

wasm_bridge_failures() ->
    SourcePath = fixture_path("campaign.js"),
    Domain = domain(ensure_qjs(), SourcePath, 5000),
    ?assertMatch(
        {error, {module_load_failed, _}},
        es_kernel_wasm_qjs:invoke(Domain#{module => fixture_path("missing.wasm")}, #{})
    ),
    ?assertMatch(
        {error, {source_read_failed, _}},
        es_kernel_wasm_qjs:invoke(Domain#{source => fixture_path("missing.js")}, #{})
    ),
    InvalidJsonDomain = source_domain(
        "invalid-json.js",
        <<"function main(_input) { return undefined; }\n">>
    ),
    ?assertMatch(
        {error, {invalid_json, _}},
        es_kernel_wasm_qjs:invoke(InvalidJsonDomain, #{<<"op">> => <<"echo">>})
    ).

wasm_domain_invalid_results() ->
    Domain = source_domain(
        "invalid-domain.js",
        <<
            "function main(input) {\n"
            "  if (input.op === 'init') return {};\n"
            "  if (input.op === 'decide' && input.command.type === 'bad_events') return {events: [{}]};\n"
            "  if (input.op === 'decide') return {};\n"
            "  if (input.op === 'apply') return {};\n"
            "}\n"
        >>
    ),
    ?assertMatch(
        {invalid_domain_result, #{}},
        (try
            es_kernel_domain:init(Domain)
        catch
            error:Reason -> Reason
        end)
    ),
    Id = aggregate_id(),
    ?assertEqual(
        {error, {invalid_domain_result, #{}}},
        es_kernel_domain:handle_command(Domain, command(?NORMAL_TYPE, invalid, Id), #{})
    ),
    ?assertEqual(
        {error, {invalid_domain_events, [#{}]}},
        es_kernel_domain:handle_command(Domain, command(?NORMAL_TYPE, bad_events, Id), #{})
    ),
    ?assertMatch(
        {invalid_domain_result, #{}},
        (try
            es_kernel_domain:apply_event(Domain, #{<<"type">> => <<"opened">>}, #{})
        catch
            error:Reason -> Reason
        end)
    ),
    ?assertError(
        {invalid_domain_event, #{}},
        es_kernel_domain:event_type(Domain, #{})
    ).

wasm_domain_execution_failures() ->
    Domain = source_domain(
        "failing-domain.js",
        <<"function main(_input) { throw new Error('boom'); }\n">>
    ),
    ?assertMatch(
        {domain_init_failed, _},
        (try
            es_kernel_domain:init(Domain)
        catch
            error:Reason -> Reason
        end)
    ),
    ?assertMatch(
        {domain_apply_failed, _},
        (try
            es_kernel_domain:apply_event(Domain, #{<<"type">> => <<"opened">>}, #{})
        catch
            error:Reason -> Reason
        end)
    ).

register_domains(QjsModule, SourcePath) ->
    ok = es_kernel_registry:register(?NORMAL_TYPE, domain(QjsModule, SourcePath, 5000)),
    ok = es_kernel_registry:register(?TIMEOUT_TYPE, domain(QjsModule, SourcePath, 6000)).

domain(QjsModule, SourcePath, Timeout) ->
    #{
        runtime => wasm,
        engine => quickjs,
        module => QjsModule,
        source => SourcePath,
        timeout => Timeout,
        limits => #{fuel => infinity, max_memory_pages => 4096}
    }.

source_domain(Name, Source) ->
    SourcePath = fixture_path(Name),
    ok = file:write_file(SourcePath, Source),
    domain(ensure_qjs(), SourcePath, 5000).

start_aggregate(Type, Id, Opts) ->
    es_kernel_aggregate:start_link(
        Type,
        Id,
        es_kernel_app:get_store_context(),
        maps:merge(#{timeout => 60000}, Opts)
    ).

command(Type, CommandType, Id) ->
    es_contract_command:new(Type, CommandType, Id, 0, #{}, #{}).

events(Type, Id) ->
    es_kernel_store:retrieve_events(
        es_kernel_app:get_store_context(),
        {Type, Id},
        es_contract_range:new(0, infinity)
    ).

aggregate_id() ->
    integer_to_binary(erlang:unique_integer([monotonic, positive])).

start_aggregate_supervisor() ->
    case whereis(es_kernel_aggregate_sup) of
        undefined ->
            {ok, _} = es_kernel_aggregate_sup:start_link(),
            ok;
        _ ->
            ok
    end.

stop_aggregate_supervisor() ->
    case whereis(es_kernel_aggregate_sup) of
        undefined ->
            ok;
        Pid ->
            unlink(Pid),
            exit(Pid, shutdown),
            wait_for_down(Pid, 100)
    end.

start_manager(StoreContext) ->
    stop_manager(),
    {ok, _} = es_kernel_mgr_aggregate:start_link(StoreContext, #{timeout => 60000}),
    ok.

stop_manager() ->
    case whereis(es_kernel_mgr_aggregate) of
        undefined ->
            ok;
        Pid ->
            unlink(Pid),
            exit(Pid, kill),
            wait_for_down(Pid, 100)
    end.

wait_for_down(Pid, Attempts) when Attempts > 0 ->
    case is_process_alive(Pid) of
        false ->
            ok;
        true ->
            timer:sleep(10),
            wait_for_down(Pid, Attempts - 1)
    end;
wait_for_down(Pid, 0) ->
    error({process_still_alive, Pid}).

wait_for_children(Dir, Attempts) when Attempts > 0 ->
    case file:list_dir(Dir) of
        {ok, [_ | _]} ->
            ok;
        _ ->
            timer:sleep(10),
            wait_for_children(Dir, Attempts - 1)
    end;
wait_for_children(Dir, 0) ->
    error({worker_scratch_not_created, Dir}).

wait_for_empty_directory(Dir, Attempts) when Attempts > 0 ->
    case file:list_dir(Dir) of
        {ok, []} ->
            ok;
        _ ->
            timer:sleep(10),
            wait_for_empty_directory(Dir, Attempts - 1)
    end;
wait_for_empty_directory(Dir, 0) ->
    error({worker_scratch_not_removed, Dir}).

ensure_qjs() ->
    Path = fixture_path("qjs.wasm"),
    ExpectedHash = binary:decode_hex(?QJS_SHA256),
    case file:read_file(Path) of
        {ok, Qjs} when byte_size(Qjs) > 0 ->
            case crypto:hash(sha256, Qjs) =:= ExpectedHash of
                true -> Path;
                false -> download_qjs(Path, ExpectedHash)
            end;
        _ ->
            download_qjs(Path, ExpectedHash)
    end.

download_qjs(Path, ExpectedHash) ->
    PartPath = Path ++ ".part",
    ok = filelib:ensure_dir(PartPath),
    _ = os:cmd("curl -fsSL " ++ ?QJS_URL ++ " -o " ++ PartPath),
    try
        {ok, Qjs} = file:read_file(PartPath),
        true = (crypto:hash(sha256, Qjs) =:= ExpectedHash),
        ok = file:rename(PartPath, Path),
        Path
    after
        _ = file:delete(PartPath)
    end.

fixture_path(Name) ->
    filename:join([filename:basedir(user_cache, "es_kernel_wasm_test"), Name]).

fixture_source() ->
    <<
        "function main(input) {\n"
        "  if (input.op === 'echo') return input;\n"
        "  if (input.op === 'loop') { for (;;) {} }\n"
        "  if (input.op === 'init') return {state: {status: 'new', claimed: false}};\n"
        "  if (input.op === 'decide') {\n"
        "    switch (input.command.type) {\n"
        "      case 'open': return input.state.status === 'new' ? {events: [{type: 'opened'}]} : {error: 'invalid'};\n"
        "      case 'claim': return input.state.claimed ? {error: 'already_claimed'} : {events: [{type: 'claimed'}]};\n"
        "      case 'reject': return {error: 'rejected'};\n"
        "      case 'crash': throw new Error('boom');\n"
        "      case 'slow': for (;;) {}\n"
        "      default: return {error: 'invalid'};\n"
        "    }\n"
        "  }\n"
        "  if (input.op === 'apply') {\n"
        "    if (input.event.type === 'opened') return {state: {status: 'open', claimed: false}};\n"
        "    if (input.event.type === 'claimed') return {state: {status: input.state.status, claimed: true}};\n"
        "    throw new Error('unknown event');\n"
        "  }\n"
        "  return {error: 'invalid'};\n"
        "}\n"
    >>.
