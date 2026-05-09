%%%-------------------------------------------------------------------
%% @doc es_xp public API
%% @end
%%%-------------------------------------------------------------------

-module(es_xp_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ok = es_kernel_registry:register(bank_account, bank_account_aggregate),

    case es_xp_sup:start_link() of
        {ok, Pid} ->
            StoreContext = es_kernel_app:get_store_context(),
            {ok, _ProjectionPid} =
                es_projection:start(StoreContext, bank_account_balance_projection, #{}),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    ok.

%% internal functions
