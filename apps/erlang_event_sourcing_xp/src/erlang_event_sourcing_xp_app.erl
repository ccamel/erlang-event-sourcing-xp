%%%-------------------------------------------------------------------
%% @doc erlang_event_sourcing_xp public API
%% @end
%%%-------------------------------------------------------------------

-module(erlang_event_sourcing_xp_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    erlang_event_sourcing_xp_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
