-module(es_store_postgres_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    {ok,
        {#{strategy => one_for_one, intensity => 1, period => 5}, [
            #{
                id => es_store_postgres,
                start => {es_store_postgres, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [es_store_postgres]
            }
        ]}}.
