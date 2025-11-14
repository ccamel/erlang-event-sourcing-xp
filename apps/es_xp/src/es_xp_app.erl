%%%-------------------------------------------------------------------
%% @doc es_xp public API
%% @end
%%%-------------------------------------------------------------------

-module(es_xp_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    es_xp_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
