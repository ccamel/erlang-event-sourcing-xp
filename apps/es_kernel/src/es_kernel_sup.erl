-module(es_kernel_sup).
-moduledoc """
Top-level supervisor for the event sourcing kernel.

Provides the supervision tree root that ensures fault tolerance and
reliability for all kernel components. Manages the lifecycle of child
processes that handle aggregate supervision and command routing.
""".

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

-doc """
Starts the es_kernel top-level supervisor.

Function returns `{ok, Pid}` on success, or `{error, Reason}` on failure.
""".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-doc """
Initializes the supervisor with its child specifications.

The supervisor uses a `one_for_one` strategy:
- es_kernel_aggregate_sup: Dynamic supervisor for aggregate instances
- es_kernel_mgr_aggregate: Singleton manager that routes commands to aggregates

Function returns `{ok, {SupFlags, ChildSpecs}}`.
""".
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags =
        #{
            strategy => one_for_one,
            intensity => 10,
            period => 5
        },

    %% Dynamic supervisor for aggregate instances
    AggregateSup =
        #{
            id => es_kernel_aggregate_sup,
            start => {es_kernel_aggregate_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [es_kernel_aggregate_sup]
        },

    %% Singleton aggregate manager
    StoreContext = es_kernel_app:get_store_context(),
    AggregateMgr =
        #{
            id => es_kernel_mgr_aggregate,
            start => {es_kernel_mgr_aggregate, start_link, [StoreContext, #{}]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [es_kernel_mgr_aggregate]
        },

    ChildSpecs = [AggregateSup, AggregateMgr],
    {ok, {SupFlags, ChildSpecs}}.
