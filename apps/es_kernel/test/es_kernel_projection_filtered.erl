-module(es_kernel_projection_filtered).

-behaviour(es_contract_projection).

-export([init/0, name/0, handle_event/2, event_filter/1]).

init() ->
    [].

name() ->
    filtered_projection.

event_filter(#{aggregate_type := user}) ->
    true;
event_filter(_) ->
    false.

handle_event(#{type := Type}, State) ->
    {ok, State ++ [Type]}.
