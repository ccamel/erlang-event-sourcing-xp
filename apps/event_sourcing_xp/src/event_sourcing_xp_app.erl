%%%-------------------------------------------------------------------
%% @doc event_sourcing_xp public API
%% @end
%%%-------------------------------------------------------------------

-module(event_sourcing_xp_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    event_sourcing_xp_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
