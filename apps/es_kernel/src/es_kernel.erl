-module(es_kernel).
-moduledoc """
Public API for the event sourcing kernel.

Provides the main interface for managing aggregate lifecycles and
dispatching commands in an event-sourced system. Abstracts the
underlying supervision and routing mechanisms behind a simple,
clean API.
""".

-export([
    start_aggregate_manager/3,
    start_aggregate_manager/4,
    dispatch/2,
    stop_aggregate_manager/1
]).

-doc """
Starts an aggregate manager with custom options.

The manager will be supervised by the es_kernel application and will
route commands to aggregate instances based on the provided Router module.

- Aggregate is the module implementing the aggregate logic.
- StoreContext is a `{EventStore, SnapshotStore}` tuple.
- Router is the module extracting routing info from commands.
- Opts are configuration options:
  - `timeout`: Timeout for operations (default: `infinity`).
  - `now_fun`: Function to get current timestamp (default: system time).

Function returns `{ok, Pid}` on success, or `{error, Reason}` on failure.
""".
-spec start_aggregate_manager(Aggregate, StoreContext, Router, Opts) ->
    {ok, Pid} | {error, Reason}
when
    Aggregate :: module(),
    StoreContext :: es_kernel_store:store_context(),
    Router :: module(),
    Opts ::
        #{
            timeout => timeout(),
            now_fun => fun(() -> non_neg_integer())
        },
    Pid :: pid(),
    Reason :: term().
start_aggregate_manager(Aggregate, StoreContext, Router, Opts) ->
    es_kernel_mgr_aggregate:start_link(Aggregate, StoreContext, Router, Opts).

-doc """
Starts an aggregate manager with default options.

- Aggregate is the module implementing the aggregate logic.
- StoreContext is a `{EventStore, SnapshotStore}` tuple.
- Router is the module extracting routing info from commands.

Function returns `{ok, Pid}` on success, or `{error, Reason}` on failure.
""".
-spec start_aggregate_manager(Aggregate, StoreContext, Router) ->
    {ok, Pid} | {error, Reason}
when
    Aggregate :: module(),
    StoreContext :: es_kernel_store:store_context(),
    Router :: module(),
    Pid :: pid(),
    Reason :: term().
start_aggregate_manager(Aggregate, StoreContext, Router) ->
    start_aggregate_manager(Aggregate, StoreContext, Router, #{}).

-doc """
Dispatches a command to the appropriate aggregate instance.

The command is routed via the manager to the correct aggregate process
based on the stream ID extracted by the router module.

- Pid is the pid of the aggregate manager process.
- Command is the command to dispatch.

Function returns `{ok, Result}` on success, or `{error, Reason}` if routing or execution fails.
""".
-spec dispatch(Pid, Command) -> {ok, Result} | {error, Reason} when
    Pid :: pid(),
    Command :: es_contract_command:t(),
    Result :: term(),
    Reason :: term().
dispatch(Pid, Command) ->
    es_kernel_mgr_aggregate:dispatch(Pid, Command).

-doc """
Stops an aggregate manager.

- Pid is the pid or registered name of the aggregate manager.

Function returns `ok` on success.
""".
-spec stop_aggregate_manager(Pid) -> ok when Pid :: pid() | atom().
stop_aggregate_manager(Pid) ->
    es_kernel_mgr_aggregate:stop(Pid).
