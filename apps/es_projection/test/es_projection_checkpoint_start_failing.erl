-module(es_projection_checkpoint_start_failing).

-export([start/0, load_checkpoint/1, store_checkpoint/2]).

start() ->
    {error, checkpoint_start_failed}.

load_checkpoint(_ProjectionName) ->
    {error, not_found}.

store_checkpoint(_ProjectionName, _Position) ->
    ok.
