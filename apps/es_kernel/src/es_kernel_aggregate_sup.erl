-module(es_kernel_aggregate_sup).
-moduledoc """
Dynamic supervisor for aggregate process instances.

Provides on-demand supervision for aggregate processes, ensuring that
each aggregate instance is properly monitored and restarted on failure.
Aggregates are started dynamically as commands are dispatched to new
stream IDs.
""".

-behaviour(supervisor).

-export([start_link/0, start_aggregate/4]).
-export([init/1]).

-define(SERVER, ?MODULE).

-doc """
Starts the aggregate dynamic supervisor.

Function returns `{ok, Pid}` on success, or `{error, Reason}` on failure.
""".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-doc """
Starts a new aggregate instance under this supervisor.

- Aggregate is the aggregate module implementing the behavior.
- StoreContext is the `{EventStore, SnapshotStore}` tuple.
- Id is the unique identifier for the aggregate instance.
- Opts are the aggregate options (timeout, now_fun, snapshot_interval).

Function returns `{ok, Pid}` on success, or `{error, Reason}` on failure.
""".
-spec start_aggregate(Aggregate, StoreContext, Id, Opts) ->
    supervisor:startchild_ret()
when
    Aggregate :: module(),
    StoreContext :: es_kernel_store:store_context(),
    Id :: es_contract_event:stream_id(),
    Opts ::
        #{
            timeout => timeout(),
            now_fun => fun(() -> non_neg_integer()),
            snapshot_interval => non_neg_integer()
        }.
start_aggregate(Aggregate, StoreContext, Id, Opts) ->
    supervisor:start_child(?SERVER, [Aggregate, StoreContext, Id, Opts]).

-doc """
Initializes the dynamic supervisor.

Uses `simple_one_for_one` strategy to allow dynamic child creation.
Each child is a `es_kernel_aggregate` process.

Function returns `{ok, {SupFlags, ChildSpecs}}`.
""".
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags =
        #{
            strategy => simple_one_for_one,
            intensity => 10,
            period => 5
        },

    AggregateSpec =
        #{
            id => es_kernel_aggregate,
            start => {es_kernel_aggregate, start_link, []},
            restart => temporary,
            shutdown => 5000,
            type => worker,
            modules => [es_kernel_aggregate]
        },

    ChildSpecs = [AggregateSpec],
    {ok, {SupFlags, ChildSpecs}}.
