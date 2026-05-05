-module(es_contract_projection_checkpoint_store).

-moduledoc """
Behaviour for projection checkpoint storage.

Projection checkpoints track the last global event position processed by a
projection runner. They are runtime progress metadata, not projection state.
""".

-doc """
Load the last processed global position for a projection.
""".
-callback load_checkpoint(ProjectionName) ->
    {ok, Position} | {error, not_found} | {error, Reason}
when
    ProjectionName :: atom(),
    Position :: es_contract_event_store:position(),
    Reason :: term().

-doc """
Store the last processed global position for a projection.
""".
-callback store_checkpoint(ProjectionName, Position) ->
    ok | {error, Reason}
when
    ProjectionName :: atom(),
    Position :: es_contract_event_store:position(),
    Reason :: term().
