-module(es_kernel_registry).
-moduledoc """
Registry that maps aggregate types to domain implementations.

A native Erlang domain implements `es_contract_aggregate`. Other runtime modules
implement `es_contract_domain` and own their descriptor fields. Registrations
happen during application startup and are then treated as immutable.
""".

%% Avoid conflict with erlang:register/2
-compile({no_auto_import, [register/2]}).

-export([register/2, lookup/1]).

-export_type([domain/0]).

-type domain() ::
    #{runtime := erlang, module := module()}
    | #{runtime := module(), term() => term()}.

-doc """
Register a domain implementation for an aggregate type.

Registration is idempotent for an identical descriptor and fails when the type
already names another implementation. Before publishing a new descriptor, the
registry loads its module and checks the required callback exports.

Invalid descriptor shapes raise `{invalid_domain_descriptor, Domain}`. An
unavailable module raises `{domain_module_unavailable, Module, Reason}`; missing
exports raise `{missing_domain_callbacks, Module, [{Name, Arity}]}`. Runtime-owned
fields are interpreted and validated by the runtime, not by the registry.
""".
-spec register(AggregateType, Domain) -> ok when
    AggregateType :: es_contract_event:aggregate_type(),
    Domain :: domain().
register(AggregateType, Domain) ->
    case lookup(AggregateType) of
        {error, not_found} ->
            validate_domain(Domain),
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

validate_domain(#{runtime := erlang, module := Module}) when is_atom(Module) ->
    validate_module(Module, es_contract_aggregate:behaviour_info(callbacks));
validate_domain(#{runtime := Runtime}) when is_atom(Runtime), Runtime =/= erlang ->
    validate_module(Runtime, es_contract_domain:behaviour_info(callbacks));
validate_domain(Domain) ->
    error({invalid_domain_descriptor, Domain}).

validate_module(Module, Callbacks) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case
                [
                    {Name, Arity}
                 || {Name, Arity} <- Callbacks,
                    not erlang:function_exported(Module, Name, Arity)
                ]
            of
                [] -> ok;
                Missing -> error({missing_domain_callbacks, Module, Missing})
            end;
        {error, Reason} ->
            error({domain_module_unavailable, Module, Reason})
    end.
