-module(es_kernel_registry).
-moduledoc """
Registry that maps conceptual aggregate types to their implementation modules.

This module provides a global, read-optimised mapping:

- `aggregate_type()` - logical name of an aggregate (e.g. `bank_account`)
- `aggregate_module()` - Erlang module implementing that aggregate (e.g. `bank_account_aggregate`)

The registry is intended to be populated during application startup and then
treated as effectively immutable at runtime. Writes are backed by
`persistent_term` and should be considered a bootstrap-only operation; reads
are cheap and can be done freely in hot paths.
""".

%% Avoid conflict with erlang:register/2
-compile({no_auto_import, [register/2]}).

-export([
    register/2,
    lookup_module/1
]).

-export_type([aggregate_module/0]).

-doc "Aggregate module identifier that handles an aggregate type.".
-type aggregate_module() :: module().

-doc """
Register a mapping between an aggregate type and its implementation module.

- `AggregateType` is the conceptual name (e.g. `bank_account`).
- `AggregateModule` is the implementing module (e.g. `bank_account_aggregate`).

This function is intended to be called during the bootstrap phase
(e.g. from application `start/2` callbacks), not from concurrent runtime
code. Concurrent calls with the same `AggregateType` are not synchronised
and may lead to last-wins behaviour.

Returns `ok` if the type is not yet registered, or if it is already
registered with the same module (idempotent). Raises
`{already_registered, {AggregateType, ExistingModule}}` if the type is
already registered with a different module.

Example:
    ok = es_kernel_registry:register(bank_account, bank_account_aggregate).
""".
-spec register(AggregateType, AggregateModule) -> ok when
    AggregateType :: es_contract_event:aggregate_type(),
    AggregateModule :: aggregate_module().
register(AggregateType, AggregateModule) ->
    case lookup_module(AggregateType) of
        {error, not_found} ->
            persistent_term:put({?MODULE, type_to_module, AggregateType}, AggregateModule),
            ok;
        {ok, AggregateModule} ->
            ok;
        {ok, ExistingModule} ->
            error({already_registered, {AggregateType, ExistingModule}})
    end.

-doc """
Looks up the aggregate module for a given aggregate type.

- AggregateType is the conceptual name.

Returns `{ok, Module}` if found, `{error, not_found}` otherwise.
""".
-spec lookup_module(AggregateType) -> {ok, AggregateModule} | {error, not_found} when
    AggregateType :: es_contract_event:aggregate_type(),
    AggregateModule :: aggregate_module().
lookup_module(AggregateType) ->
    case persistent_term:get({?MODULE, type_to_module, AggregateType}, undefined) of
        undefined -> {error, not_found};
        Module -> {ok, Module}
    end.
