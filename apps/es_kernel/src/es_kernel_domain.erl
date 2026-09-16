-module(es_kernel_domain).
-moduledoc """
Executes event-sourced domain callbacks implemented in Erlang or WebAssembly.

Both runtimes obey the same command/event/state contract. The kernel remains
responsible for persistence, replay, snapshots, and process lifecycle.
""".

-export([init/1, handle_command/3, apply_event/3, event_type/2]).

-spec init(es_kernel_registry:domain()) -> es_contract_aggregate:aggregate_state().
init(#{runtime := erlang, module := Module}) ->
    Module:init();
init(#{runtime := wasm} = Domain) ->
    case es_kernel_wasm_qjs:invoke(Domain, #{<<"op">> => <<"init">>}) of
        {ok, #{<<"state">> := State}} -> State;
        {ok, Result} -> error({invalid_domain_result, Result});
        {error, Reason} -> error({domain_init_failed, Reason})
    end.

-spec handle_command(
    es_kernel_registry:domain(),
    es_contract_command:t(),
    es_contract_aggregate:aggregate_state()
) -> {ok, [es_contract_event:payload()]} | {error, term()}.
handle_command(#{runtime := erlang, module := Module}, Command, State) ->
    Module:handle_command(Command, State);
handle_command(#{runtime := wasm} = Domain, Command, State) ->
    Input = #{
        <<"op">> => <<"decide">>,
        <<"command">> => #{
            <<"type">> => maps:get(type, Command),
            <<"payload">> => maps:get(payload, Command)
        },
        <<"state">> => State
    },
    case es_kernel_wasm_qjs:invoke(Domain, Input) of
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
apply_event(#{runtime := erlang, module := Module}, Event, State) ->
    Module:apply_event(Event, State);
apply_event(#{runtime := wasm} = Domain, Event, State) ->
    Input = #{<<"op">> => <<"apply">>, <<"event">> => Event, <<"state">> => State},
    case es_kernel_wasm_qjs:invoke(Domain, Input) of
        {ok, #{<<"state">> := NewState}} -> NewState;
        {ok, Result} -> error({invalid_domain_result, Result});
        {error, Reason} -> error({domain_apply_failed, Reason})
    end.

-spec event_type(es_kernel_registry:domain(), es_contract_event:payload()) ->
    es_contract_event:type().
event_type(#{runtime := erlang, module := Module}, Event) ->
    Module:event_type(Event);
event_type(#{runtime := wasm}, #{<<"type">> := Type}) when is_binary(Type), byte_size(Type) > 0 ->
    Type;
event_type(#{runtime := wasm}, Event) ->
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
