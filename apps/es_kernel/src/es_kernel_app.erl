-module(es_kernel_app).
-moduledoc """
Application callback module for the event sourcing kernel.

Defines the entry point for starting and stopping the es_kernel application
within the Erlang/OTP application framework.
""".

-behaviour(application).

-export([start/2, stop/1, get_store_context/0]).

-doc """
Starts the es_kernel application.

This function is called by the application controller when starting
the es_kernel application. It starts the top-level supervisor.

- StartType is the start type (normal, takeover, or failover).
- StartArgs are application-specific start arguments.

Function returns `{ok, Pid}` where Pid is the supervisor process,
or `{error, Reason}` if startup fails.
""".
-spec start(StartType, StartArgs) -> {ok, Pid} | {error, Reason} when
    StartType :: application:start_type(),
    StartArgs :: term(),
    Pid :: pid(),
    Reason :: term().
start(_StartType, _StartArgs) ->
    StoreContext = get_store_context(),
    ok = es_kernel_store:start(StoreContext),
    es_kernel_sup:start_link().

-doc """
Stops the es_kernel application.

This function is called by the application controller when stopping
the es_kernel application.

- State is the application state returned by start/2.

Function returns `ok`.
""".
-spec stop(State) -> ok when State :: term().
stop(_State) ->
    StoreContext = get_store_context(),
    es_kernel_store:stop(StoreContext),
    ok.

-doc """
Retrieves the store context from the application environment.

Reads the configured event_store and snapshot_store modules from the
es_kernel application environment and constructs a store_context() tuple.

Function returns `{EventStore, SnapshotStore}` where both are module names.
Defaults to `es_store_ets` for both if not configured.
""".
-spec get_store_context() -> es_kernel_store:store_context().
get_store_context() ->
    EventStore = application:get_env(es_kernel, event_store, es_store_ets),
    SnapshotStore = application:get_env(es_kernel, snapshot_store, es_store_ets),
    {EventStore, SnapshotStore}.
