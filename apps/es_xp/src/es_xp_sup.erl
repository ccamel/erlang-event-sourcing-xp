%%%-------------------------------------------------------------------
%% @doc es_xp top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(es_xp_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([]) ->
    SupFlags =
        #{
            strategy => one_for_all,
            intensity => 0,
            period => 1
        },
    ChildSpecs = [
        #{
            id => es_xp_balance_view,
            start => {es_xp_balance_view, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [es_xp_balance_view]
        },
        %% one_for_all: the runner restarts with the view, so it reloads the view's
        %% (cleared) checkpoint and replays the log instead of resuming mid-stream.
        #{
            id => bank_account_balance_projection,
            start =>
                {es_projection, start_link, [
                    es_kernel_app:get_store_context(),
                    bank_account_balance_projection,
                    #{checkpoint_store => es_xp_balance_view}
                ]},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [es_projection]
        },
        #{
            id => es_xp_http,
            start => {es_xp_http, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [es_xp_http]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
