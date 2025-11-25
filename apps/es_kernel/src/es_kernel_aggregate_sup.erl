-module(es_kernel_aggregate_sup).
-moduledoc """
Dynamic supervisor for aggregate processes.

This supervisor owns the lifecycle of aggregate worker processes. It
starts and supervises aggregate processes on demand, without
automatically restarting them on failure. An aggregate that crashes
remains terminated until a caller explicitly starts a new process.
""".

-behaviour(supervisor).

-export([start_link/0, start_aggregate/4]).
-export([init/1]).

-define(SERVER, ?MODULE).

-doc """
Starts the dynamic supervisor responsible for aggregate processes and
registers it under its module name.
""".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-doc """
Starts an aggregate worker process under this supervisor.

The caller controls when aggregate processes are created or recreated.
If a child process crashes, it is not restarted automatically; calling
`start_aggregate/4` again is the way to start a new aggregate process.
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
    ChildSpec =
        #{
            id => {es_kernel_aggregate, Aggregate, Id},
            start => {es_kernel_aggregate, start_link, [Aggregate, StoreContext, Id, Opts]},
            restart => temporary,
            shutdown => 5000,
            type => worker,
            modules => [es_kernel_aggregate]
        },
    supervisor:start_child(?SERVER, ChildSpec).

-doc """
Initializes the supervisor with a dynamic strategy suitable for
on-demand aggregate processes.
""".
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags =
        #{
            strategy => one_for_one,
            intensity => 10,
            period => 5
        },

    ChildSpecs = [],
    {ok, {SupFlags, ChildSpecs}}.
