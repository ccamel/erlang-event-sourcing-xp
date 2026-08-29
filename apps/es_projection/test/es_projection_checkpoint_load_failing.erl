-module(es_projection_checkpoint_load_failing).

-export([load_checkpoint/1, store_checkpoint/2]).

load_checkpoint(_ProjectionName) ->
    {error, checkpoint_load_failed}.

store_checkpoint(_ProjectionName, _Position) ->
    ok.
