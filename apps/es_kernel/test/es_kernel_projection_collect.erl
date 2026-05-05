-module(es_kernel_projection_collect).

-behaviour(es_contract_projection).

-export([init/0, name/0, handle_event/2]).

init() ->
    [].

name() ->
    collect_projection.

handle_event(#{type := Type}, State) ->
    {ok, State ++ [Type]}.
