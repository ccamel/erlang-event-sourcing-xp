-module(es_kernel_wasm_qjs).
-moduledoc """
Runs one JSON request through a QuickJS WebAssembly command.

Each invocation gets a fresh WASM instance, a private read-only directory, no
network, deterministic random input, bounded memory, and a killable process.
""".

-export([invoke/2]).

-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_LIMITS, #{fuel => infinity, max_memory_pages => 4096}).

-spec invoke(es_kernel_registry:domain(), map()) -> {ok, term()} | {error, term()}.
invoke(#{engine := quickjs, module := ModulePath, source := SourcePath} = Domain, Input) ->
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
        es_kernel,
        wasm_scratch_dir,
        filename:basedir(user_cache, "es_kernel_wasm")
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
