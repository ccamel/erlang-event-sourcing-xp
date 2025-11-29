%%%-------------------------------------------------------------------
%% @doc es_xp public API
%% @end
%%%-------------------------------------------------------------------

-module(es_xp_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ok = es_kernel_registry:register(bank_account, bank_account_aggregate),

    es_xp_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
