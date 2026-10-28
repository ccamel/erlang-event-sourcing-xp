-module(es_kernel_domain).
-moduledoc """
Executes event-sourced domain callbacks through their registered runtime.

Native Erlang domains implement `es_contract_aggregate`; other runtime modules
implement `es_contract_domain` and own the rest of their descriptor.
The kernel remains responsible for persistence, replay, snapshots, and process
lifecycle.
""".

-export([init/1, handle_command/3, apply_event/3, event_type/2]).

-spec init(es_kernel_registry:domain()) -> es_contract_aggregate:aggregate_state().
init(#{runtime := erlang, module := Module}) ->
    Module:init();
init(#{runtime := Runtime} = Domain) ->
    Runtime:init(Domain).

-spec handle_command(
    es_kernel_registry:domain(),
    es_contract_command:t(),
    es_contract_aggregate:aggregate_state()
) -> {ok, [es_contract_event:payload()]} | {error, term()}.
handle_command(#{runtime := erlang, module := Module}, Command, State) ->
    Module:handle_command(Command, State);
handle_command(#{runtime := Runtime} = Domain, Command, State) ->
    Runtime:handle_command(Domain, Command, State).

-spec apply_event(
    es_kernel_registry:domain(),
    es_contract_event:payload(),
    es_contract_aggregate:aggregate_state()
) -> es_contract_aggregate:aggregate_state().
apply_event(#{runtime := erlang, module := Module}, Event, State) ->
    Module:apply_event(Event, State);
apply_event(#{runtime := Runtime} = Domain, Event, State) ->
    Runtime:apply_event(Domain, Event, State).

-spec event_type(es_kernel_registry:domain(), es_contract_event:payload()) ->
    es_contract_event:type().
event_type(#{runtime := erlang, module := Module}, Event) ->
    Module:event_type(Event);
event_type(#{runtime := Runtime} = Domain, Event) ->
    Runtime:event_type(Domain, Event).
