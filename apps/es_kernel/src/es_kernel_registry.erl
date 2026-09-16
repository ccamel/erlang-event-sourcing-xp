-module(es_kernel_registry).
-moduledoc """
Registry that maps aggregate types to domain implementations.

A domain is either an Erlang module implementing `es_contract_aggregate` or a
WebAssembly-hosted implementation. Registrations happen during application
startup and are then treated as immutable.
""".

%% Avoid conflict with erlang:register/2
-compile({no_auto_import, [register/2]}).

-export([register/2, lookup/1]).

-export_type([domain/0]).

-type domain() ::
    #{runtime := erlang, module := module()}
    | #{
        runtime := wasm,
        engine := quickjs,
        module := file:filename_all(),
        source := file:filename_all(),
        timeout => pos_integer(),
        limits => map()
    }.

-doc """
Register a domain implementation for an aggregate type.

Registration is idempotent for an identical descriptor and fails when the type
already names another implementation.
""".
-spec register(AggregateType, Domain) -> ok when
    AggregateType :: es_contract_event:aggregate_type(),
    Domain :: domain().
register(AggregateType, Domain) ->
    case lookup(AggregateType) of
        {error, not_found} ->
            persistent_term:put({?MODULE, type_to_domain, AggregateType}, Domain),
            ok;
        {ok, Domain} ->
            ok;
        {ok, ExistingDomain} ->
            error({already_registered, {AggregateType, ExistingDomain}})
    end.

-doc "Look up the domain implementation registered for an aggregate type.".
-spec lookup(AggregateType) -> {ok, Domain} | {error, not_found} when
    AggregateType :: es_contract_event:aggregate_type(),
    Domain :: domain().
lookup(AggregateType) ->
    case persistent_term:get({?MODULE, type_to_domain, AggregateType}, undefined) of
        undefined -> {error, not_found};
        Domain -> {ok, Domain}
    end.
