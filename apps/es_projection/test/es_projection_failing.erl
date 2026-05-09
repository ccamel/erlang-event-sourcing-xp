-module(es_projection_failing).

-behaviour(es_contract_projection).

-export([init/0, name/0, handle_event/2]).

init() ->
    [].

name() ->
    failing_projection.

handle_event(#{type := fail}, _State) ->
    {error, boom};
handle_event(#{type := Type}, State) ->
    {ok, State ++ [Type]}.
