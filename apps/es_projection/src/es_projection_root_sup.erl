-module(es_projection_root_sup).

-moduledoc """
Top-level supervisor for the projection application.
""".

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 5
    },
    ChildSpecs = [
        #{
            id => es_projection_sup,
            start => {es_projection_sup, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => supervisor,
            modules => [es_projection_sup]
        },
        #{
            id => es_projection_mgr,
            start => {es_projection_mgr, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [es_projection_mgr]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
