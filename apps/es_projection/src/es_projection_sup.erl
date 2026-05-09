-module(es_projection_sup).

-moduledoc """
Dynamic supervisor for projection runners.
""".

-behaviour(supervisor).

-export([start_link/0, start_projection/3]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec start_projection(StoreContext, ProjectionModule, Options) ->
    supervisor:startchild_ret()
when
    StoreContext :: es_kernel_store:store_context(),
    ProjectionModule :: module(),
    Options :: es_projection:options().
start_projection(StoreContext, ProjectionModule, Options) ->
    ProjectionName = ProjectionModule:name(),
    ChildSpec = #{
        id => {es_projection, ProjectionName},
        start => {es_projection, start_link, [StoreContext, ProjectionModule, Options]},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [es_projection]
    },
    supervisor:start_child(?SERVER, ChildSpec).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 5
    },
    {ok, {SupFlags, []}}.
