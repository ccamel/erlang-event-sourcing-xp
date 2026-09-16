%%%-------------------------------------------------------------------
%% @doc es_xp public API
%% @end
%%%-------------------------------------------------------------------

-module(es_xp_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ok = es_kernel_registry:register(
        bank_account, #{runtime => erlang, module => bank_account_aggregate}
    ),
    case application:get_env(es_xp, qjs_module) of
        {ok, QjsModule} ->
            PrivDir = code:priv_dir(es_xp),
            ok = es_kernel_registry:register(
                promotion_campaign,
                #{
                    runtime => wasm,
                    engine => quickjs,
                    module => QjsModule,
                    source => filename:join(PrivDir, "promotion_campaign.js"),
                    timeout => 5000,
                    limits => #{
                        fuel => infinity,
                        max_memory_pages => 4096,
                        max_heap_words => 16 * 1024 * 1024
                    }
                }
            );
        undefined ->
            ok
    end,

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
