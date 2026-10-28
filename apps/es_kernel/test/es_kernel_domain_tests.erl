-module(es_kernel_domain_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TYPE, es_kernel_custom_runtime_test).
-define(STORE, {es_store_ets, es_store_ets}).

custom_runtime_aggregate_test() ->
    with_registration(?TYPE, fun() ->
        ok = es_kernel_registry:register(?TYPE, domain()),
        with_store(fun() ->
            replay_without_snapshot(),
            replay_with_snapshot()
        end)
    end).

replay_without_snapshot() ->
    Id = <<"replay">>,
    Stream = {?TYPE, Id},
    with_aggregate(Id, #{}, fun(Pid) ->
        ?assertEqual(ok, execute(Pid, Id, credit, 2)),
        ?assertEqual({error, insufficient_balance}, execute(Pid, Id, withdraw, 17)),
        ?assertEqual(ok, execute(Pid, Id, idle, undefined)),
        ?assertMatch(
            [#{sequence := 1, type := <<"balance_changed">>, payload := {credit, 6}}],
            events(Stream)
        ),
        ?assertEqual({error, not_found}, es_kernel_store:load_latest(?STORE, Stream))
    end),
    with_aggregate(Id, #{}, fun(Pid) ->
        ?assertEqual(ok, execute(Pid, Id, withdraw, 16)),
        ?assertEqual({error, insufficient_balance}, execute(Pid, Id, withdraw, 1)),
        ?assertMatch(
            [#{sequence := 1, payload := {credit, 6}}, #{sequence := 2, payload := {debit, 16}}],
            events(Stream)
        )
    end).

replay_with_snapshot() ->
    Id = <<"snapshot">>,
    Stream = {?TYPE, Id},
    with_aggregate(Id, #{snapshot_interval => 2}, fun(Pid) ->
        ?assertEqual(ok, execute(Pid, Id, credit, 2)),
        ?assertEqual(ok, execute(Pid, Id, credit, 3)),
        ?assertEqual(ok, execute(Pid, Id, credit, 1)),
        ?assertMatch(
            {ok, #{sequence := 2, state := #{balance := 25}}},
            es_kernel_store:load_latest(?STORE, Stream)
        )
    end),
    with_aggregate(Id, #{}, fun(Pid) ->
        ?assertEqual(ok, execute(Pid, Id, withdraw, 28)),
        ?assertEqual({error, insufficient_balance}, execute(Pid, Id, withdraw, 1)),
        ?assertMatch(
            [#{sequence := 4, payload := {debit, 28}}],
            lists:nthtail(3, events(Stream))
        )
    end).

registration_validation_test() ->
    Type = es_kernel_invalid_runtime_test,
    with_registration(Type, fun() ->
        Invalid = [
            invalid,
            [],
            #{},
            #{runtime => <<"runtime">>},
            #{runtime => erlang},
            #{runtime => erlang, module => <<"module">>}
        ],
        lists:foreach(
            fun(Domain) ->
                ?assertError(
                    {invalid_domain_descriptor, Domain},
                    es_kernel_registry:register(Type, Domain)
                ),
                ?assertEqual({error, not_found}, es_kernel_registry:lookup(Type))
            end,
            Invalid
        ),
        MissingModule = es_kernel_nonexistent_runtime_fixture,
        lists:foreach(
            fun(Domain) ->
                ?assertError(
                    {domain_module_unavailable, MissingModule, nofile},
                    es_kernel_registry:register(Type, Domain)
                ),
                ?assertEqual({error, not_found}, es_kernel_registry:lookup(Type))
            end,
            [#{runtime => MissingModule}, #{runtime => erlang, module => MissingModule}]
        ),
        ?assertError(
            {missing_domain_callbacks, es_kernel_aggregate, _},
            es_kernel_registry:register(Type, #{runtime => es_kernel_aggregate})
        ),
        ?assertEqual({error, not_found}, es_kernel_registry:lookup(Type)),
        ?assertError(
            {missing_domain_callbacks, es_kernel_test_runtime, _},
            es_kernel_registry:register(Type, #{runtime => erlang, module => es_kernel_test_runtime})
        ),
        ?assertEqual({error, not_found}, es_kernel_registry:lookup(Type)),
        Domain = domain(),
        ?assertEqual(ok, es_kernel_registry:register(Type, Domain)),
        ?assertEqual(ok, es_kernel_registry:register(Type, Domain)),
        ?assertEqual({ok, Domain}, es_kernel_registry:lookup(Type)),
        ?assertError(
            {already_registered, {Type, Domain}},
            es_kernel_registry:register(Type, Domain#{initial := 20})
        ),
        ?assertError(
            {already_registered, {Type, Domain}},
            es_kernel_registry:register(Type, #{runtime => MissingModule})
        ),
        ?assertEqual({ok, Domain}, es_kernel_registry:lookup(Type))
    end).

native_registration_test() ->
    Type = es_kernel_native_runtime_test,
    with_registration(Type, fun() ->
        Domain = #{runtime => erlang, module => bank_account_aggregate},
        ?assertEqual(ok, es_kernel_registry:register(Type, Domain)),
        ?assertEqual(ok, es_kernel_registry:register(Type, Domain)),
        ?assertEqual({ok, Domain}, es_kernel_registry:lookup(Type))
    end).

domain() ->
    #{
        runtime => es_kernel_test_runtime,
        initial => 10,
        step => 3,
        event_type => <<"balance_changed">>
    }.

execute(Pid, Id, Type, Payload) ->
    Command = es_contract_command:new(?TYPE, Type, Id, 0, #{}, Payload),
    es_kernel_aggregate:execute(Pid, Command).

events(Stream) ->
    {ok, Events} = es_kernel_store:fold(
        ?STORE,
        Stream,
        fun(Event, _Sequence, Acc) -> [Event | Acc] end,
        [],
        es_contract_range:new(1, infinity)
    ),
    lists:reverse(Events).

with_aggregate(Id, Options, Fun) ->
    {ok, Pid} = es_kernel_aggregate:start_link(?TYPE, Id, ?STORE, Options#{timeout => 60000}),
    try
        Fun(Pid)
    after
        gen_server:stop(Pid)
    end.

with_registration(Type, Fun) ->
    ?assertEqual({error, not_found}, es_kernel_registry:lookup(Type)),
    try
        Fun()
    after
        persistent_term:erase({es_kernel_registry, type_to_domain, Type})
    end.

with_store(Fun) ->
    Settings = [
        {event_table_name, es_kernel_runtime_test_events},
        {snapshot_table_name, es_kernel_runtime_test_snapshots},
        {position_counter_table_name, es_kernel_runtime_test_positions},
        {stream_sequence_table_name, es_kernel_runtime_test_sequences}
    ],
    Previous = [{Key, application:get_env(es_store_ets, Key)} || {Key, _} <- Settings],
    lists:foreach(
        fun({Key, Value}) -> application:set_env(es_store_ets, Key, Value) end, Settings
    ),
    try
        ok = es_store_ets:start(),
        Fun()
    after
        es_store_ets:stop(),
        lists:foreach(
            fun
                ({Key, {ok, Value}}) -> application:set_env(es_store_ets, Key, Value);
                ({Key, undefined}) -> application:unset_env(es_store_ets, Key)
            end,
            Previous
        )
    end.
