-module(es_projection_failing).

-behaviour(es_contract_projection).

-export([init/0, name/0, handle_event/3]).

init() ->
    [].

name() ->
    failing_projection.

handle_event(#{type := fail}, _Position, _State) ->
    {error, boom};
handle_event(#{type := Type}, Position, State) ->
    {ok, State ++ [{Type, Position}]}.
