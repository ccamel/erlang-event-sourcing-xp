-module(es_projection_collect).

-behaviour(es_contract_projection).

-export([init/0, name/0, handle_event/3]).

init() ->
    [].

name() ->
    collect_projection.

handle_event(#{type := Type}, Position, State) ->
    {ok, State ++ [{Type, Position}]}.
