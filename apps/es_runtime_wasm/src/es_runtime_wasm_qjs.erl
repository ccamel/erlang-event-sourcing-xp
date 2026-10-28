-module(es_runtime_wasm_qjs).
-moduledoc """
Runs one JSON request through a QuickJS WebAssembly command.

Each invocation gets a fresh WASM instance, a private read-only directory, no
network, deterministic random input, bounded memory, and a killable process.
""".

-behaviour(es_contract_domain).

-export([init/1, handle_command/3, apply_event/3, event_type/2, invoke/2]).

-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_LIMITS, #{fuel => infinity, max_memory_pages => 4096}).

-spec init(es_kernel_registry:domain()) -> es_contract_aggregate:aggregate_state().
init(Domain) ->
    case invoke(Domain, #{<<"op">> => <<"init">>}) of
        {ok, #{<<"state">> := State}} -> State;
        {ok, Result} -> error({invalid_domain_result, Result});
        {error, Reason} -> error({domain_init_failed, Reason})
    end.

-spec handle_command(
    es_kernel_registry:domain(),
    es_contract_command:t(),
    es_contract_aggregate:aggregate_state()
) -> {ok, [es_contract_event:payload()]} | {error, term()}.
handle_command(Domain, Command, State) ->
    Input = #{
        <<"op">> => <<"decide">>,
        <<"command">> => #{
            <<"type">> => maps:get(type, Command),
            <<"payload">> => maps:get(payload, Command)
        },
        <<"state">> => State
    },
    case invoke(Domain, Input) of
        {ok, #{<<"events">> := Events}} when is_list(Events) ->
            validate_events(Events);
        {ok, #{<<"error">> := Reason}} ->
            {error, Reason};
        {ok, Result} ->
            {error, {invalid_domain_result, Result}};
        {error, Reason} ->
            {error, {domain_execution_failed, Reason}}
    end.

-spec apply_event(
    es_kernel_registry:domain(),
    es_contract_event:payload(),
    es_contract_aggregate:aggregate_state()
) -> es_contract_aggregate:aggregate_state().
apply_event(Domain, Event, State) ->
    Input = #{<<"op">> => <<"apply">>, <<"event">> => Event, <<"state">> => State},
    case invoke(Domain, Input) of
        {ok, #{<<"state">> := NewState}} -> NewState;
        {ok, Result} -> error({invalid_domain_result, Result});
        {error, Reason} -> error({domain_apply_failed, Reason})
    end.

-spec event_type(es_kernel_registry:domain(), es_contract_event:payload()) ->
    es_contract_event:type().
event_type(_Domain, #{<<"type">> := Type}) when is_binary(Type), byte_size(Type) > 0 ->
    Type;
event_type(_Domain, Event) ->
    error({invalid_domain_event, Event}).

validate_events(Events) ->
    case
        lists:all(
            fun
                (#{<<"type">> := Type}) when is_binary(Type), byte_size(Type) > 0 -> true;
                (_) -> false
            end,
            Events
        )
    of
        true -> {ok, Events};
        false -> {error, {invalid_domain_events, Events}}
    end.

-spec invoke(es_kernel_registry:domain(), map()) -> {ok, term()} | {error, term()}.
invoke(#{module := ModulePath, source := SourcePath} = Domain, Input) ->
    Timeout = maps:get(timeout, Domain, ?DEFAULT_TIMEOUT),
    Limits = maps:merge(?DEFAULT_LIMITS, maps:get(limits, Domain, #{})),
    case {wasm:load_file(ModulePath), file:read_file(SourcePath)} of
        {{ok, Module}, {ok, Source}} ->
            Script = script(Source, Input),
            run(Module, Script, Timeout, Limits);
        {{error, Reason}, _} ->
            {error, {module_load_failed, Reason}};
        {_, {error, Reason}} ->
            {error, {source_read_failed, Reason}}
    end.

script(Source, Input) ->
    InputJson = iolist_to_binary(json:encode(json_term(Input))),
    JsonContainer = json:encode(#{<<"input">> => InputJson}),
    iolist_to_binary([
        Source,
        <<"\nprint(JSON.stringify(main(JSON.parse(">>,
        JsonContainer,
        <<".input))));\n">>
    ]).

run(Module, Script, Timeout, Limits) ->
    Base = application:get_env(
        es_runtime_wasm,
        wasm_scratch_dir,
        filename:basedir(user_cache, "es_runtime_wasm")
    ),
    Dir = filename:join(Base, integer_to_list(erlang:unique_integer([positive]))),
    ScriptPath = filename:join(Dir, "main.js"),
    ok = filelib:ensure_dir(ScriptPath),
    try
        ok = file:write_file(ScriptPath, Script),
        collect(Module, Dir, Timeout, Limits)
    after
        _ = file:del_dir_r(Dir)
    end.

collect(Module, Dir, Timeout, Limits) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() -> guarded_execute(Parent, Ref, Module, Dir, Limits) end),
    receive
        {Ref, Result} ->
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Pid, Reason} ->
            {error, {worker_crashed, Reason}}
    after Timeout ->
        Pid ! cancel,
        receive
            {'DOWN', Monitor, process, Pid, _} ->
                ok
        after 1000 ->
            exit(Pid, kill),
            erlang:demonitor(Monitor, [flush])
        end,
        receive
            {Ref, _} ->
                ok
        after 0 ->
            ok
        end,
        {error, timeout}
    end.

guarded_execute(Parent, Ref, Module, Dir, Limits) ->
    process_flag(trap_exit, true),
    ParentMonitor = erlang:monitor(process, Parent),
    Guard = self(),
    Worker = spawn_link(fun() -> Guard ! {worker_result, execute(Module, Dir, Limits)} end),
    try
        case await_worker(Parent, ParentMonitor, Worker) of
            {reply, Result} ->
                Parent ! {Ref, Result};
            {crashed, Reason} ->
                Parent ! {Ref, {error, {worker_crashed, Reason}}};
            cancelled ->
                ok;
            parent_down ->
                ok
        end
    after
        _ = file:del_dir_r(Dir)
    end.

await_worker(Parent, ParentMonitor, Worker) ->
    receive
        cancel ->
            stop_worker(Worker),
            cancelled;
        {'DOWN', ParentMonitor, process, Parent, _} ->
            stop_worker(Worker),
            parent_down;
        {worker_result, Result} ->
            await_worker_exit(Parent, ParentMonitor, Worker, Result);
        {'EXIT', Worker, Reason} ->
            {crashed, Reason}
    after infinity ->
        {crashed, guard_timeout}
    end.

await_worker_exit(Parent, ParentMonitor, Worker, Result) ->
    receive
        cancel ->
            stop_worker(Worker),
            cancelled;
        {'DOWN', ParentMonitor, process, Parent, _} ->
            stop_worker(Worker),
            parent_down;
        {'EXIT', Worker, normal} ->
            {reply, Result};
        {'EXIT', Worker, Reason} ->
            {crashed, Reason}
    after infinity ->
        {crashed, guard_timeout}
    end.

stop_worker(Worker) ->
    exit(Worker, kill),
    receive
        {'EXIT', Worker, _} ->
            ok
    after 1000 ->
        ok
    end.

execute(Module, Dir, Limits) ->
    _ = maybe_limit_heap(Limits),
    Self = self(),
    Config = #{
        args => [<<"qjs">>, <<"main.js">>],
        env => #{},
        dirs => [{<<"/">>, Dir, read}],
        random => {seed, 0},
        clocks => [],
        net => none,
        stdout => fun(Data) ->
            Self ! {stdout, Data},
            ok
        end,
        stderr => fun(Data) ->
            Self ! {stderr, Data},
            ok
        end
    },
    WasmLimits = maps:remove(max_heap_words, Limits),
    case wasm:instantiate(Module, wasi_preview1:imports(Config), WasmLimits) of
        {error, Reason} ->
            {error, {instantiate_failed, Reason}};
        {ok, Instance} ->
            try
                decode_result(wasm:call(Instance, <<"_start">>, [], WasmLimits))
            after
                ok = wasm:destroy(Instance)
            end
    end.

maybe_limit_heap(#{max_heap_words := Words}) ->
    process_flag(max_heap_size, #{size => Words, kill => true, error_logger => true});
maybe_limit_heap(_) ->
    ok.

decode_result(CallResult) ->
    Stdout = drain(stdout, <<>>),
    Stderr = drain(stderr, <<>>),
    case CallResult of
        {ok, _} ->
            decode_json(Stdout);
        {error, Error} ->
            case wasi_preview1:exit_code(Error) of
                {ok, 0} -> decode_json(Stdout);
                {ok, Code} -> {error, {guest_exit, Code, Stderr}};
                error -> {error, Error}
            end
    end.

decode_json(Output) ->
    try
        {ok, json:decode(Output)}
    catch
        _:_ -> {error, {invalid_json, Output}}
    end.

drain(Channel, Acc) ->
    receive
        {Channel, Data} -> drain(Channel, <<Acc/binary, Data/binary>>)
    after 0 ->
        Acc
    end.

json_term(Map) when is_map(Map) ->
    maps:from_list([{json_key(Key), json_term(Value)} || {Key, Value} <- maps:to_list(Map)]);
json_term(List) when is_list(List) ->
    [json_term(Value) || Value <- List];
json_term(Tuple) when is_tuple(Tuple) ->
    json_term(tuple_to_list(Tuple));
json_term(true) ->
    true;
json_term(false) ->
    false;
json_term(null) ->
    null;
json_term(Atom) when is_atom(Atom) ->
    atom_to_binary(Atom);
json_term(Value) when is_binary(Value); is_integer(Value); is_float(Value) ->
    Value;
json_term(Value) ->
    error({unsupported_json_term, Value}).

json_key(Key) when is_binary(Key) -> Key;
json_key(Key) when is_atom(Key) -> atom_to_binary(Key);
json_key(Key) when is_integer(Key) -> integer_to_binary(Key);
json_key(Key) -> error({unsupported_json_key, Key}).
