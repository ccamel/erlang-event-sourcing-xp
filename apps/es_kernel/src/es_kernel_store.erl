-module(es_kernel_store).
-moduledoc """
Kernel API for event store operations.

This module provides:
- **Domain types**: event, snapshot, sequence, stream_id, etc.
- **Constructors and accessors**: `new_event/...`, `new_snapshot/...`, field getters
- **Storage operations**: wrappers around backend implementations

A `store_context()` tuple `{EventStore, SnapshotStore}` identifies the backend modules.
Both may be the same module if it implements both event and snapshot storage.
""".

-export([
    append/3,
    fold/5,
    retrieve_events/3,
    store/2,
    load_latest/2,
    new_snapshot/5,
    snapshot_stream_id/1,
    snapshot_aggregate_type/1,
    snapshot_sequence/1,
    snapshot_timestamp/1,
    snapshot_state/1,
    id/1,
    type/1,
    stream_id/1,
    sequence/1,
    timestamp/1,
    tags/1,
    metadata/1,
    payload/1,
    aggregate_type/1,
    new_event/8, new_event/6
]).

-export_type([store_context/0]).

-type store_backend() :: module().
-type store_context() :: {store_backend(), store_backend()}.

-doc """
Appends a list of events to the event store using the specified store module.

This is the primary mechanism for persisting domain events. All events in the list
must target the same stream and have unique identifiers. The store backend ensures
atomic persistence and maintains sequence ordering.
""".
-spec append(StoreContext, StreamId, Events) -> ok when
    StoreContext :: store_context(),
    StreamId :: es_contract_event:stream_id(),
    Events :: [es_contract_event:t()].
append({EventModule, _}, StreamId, Events) when is_list(Events) ->
    %% Validate that all events target the same StreamId
    ok = lists:foreach(
        fun(Event) ->
            case stream_id(Event) of
                StreamId ->
                    ok;
                WrongStreamId ->
                    erlang:error({badarg, WrongStreamId})
            end
        end,
        Events
    ),

    %% Detect duplicates (same event id twice in the batch)
    SeenIds = [id(E) || E <- Events],
    case length(SeenIds) =:= length(lists:usort(SeenIds)) of
        true ->
            ok;
        false ->
            erlang:error(duplicate_event)
    end,

    EventModule:append(StreamId, Events).

-doc """
Folds events from the event store into an accumulator using the specified persistence module.

This is the core operation for event replay and state reconstruction. The backend
retrieves events within the specified range and applies the fold function in sequence order.
""".
-spec fold(StoreContext, StreamId, Fun, Acc0, Range) -> Acc1 when
    StoreContext :: store_context(),
    StreamId :: es_contract_event:stream_id(),
    Fun :: fun((Event :: es_contract_event:t(), AccIn) -> AccOut),
    Acc0 :: term(),
    Range :: es_contract_range:range(),
    Acc1 :: term(),
    AccIn :: term(),
    AccOut :: term().
fold({EventModule, _}, StreamId, Fun, InitialResult, Range) ->
    EventModule:fold(StreamId, Fun, InitialResult, Range).

-doc """
Retrieves events for a given stream using the specified store module and range.

This is a convenience wrapper around fold/5 that collects all events into a list.
""".
-spec retrieve_events(StoreContext, StreamId, Range) -> Result when
    StoreContext :: store_context(),
    StreamId :: es_contract_event:stream_id(),
    Range :: es_contract_range:range(),
    Result :: [es_contract_event:t()].
retrieve_events(StoreContext, StreamId, Range) ->
    fold(
        StoreContext,
        StreamId,
        fun(Event, Acc) -> Acc ++ [Event] end,
        [],
        Range
    ).

-doc """
Creates a new event map.

- StreamId is the unique identifier for the stream.
- AggregateType is the aggregate type to which the event belongs.
- Type is the type of the event.
- Sequence is the sequence number of the event in the stream.
- Tags is a list of tags associated with the event.
- Timestamp is the timestamp when the event occurred.
- Metadata is additional contextual information for the event.
- Payload is the actual data of the event.

The timestamp is stored inside the metadata map under the `timestamp` key, so callers
can access it uniformly through metadata.
""".
-spec new_event(
    StreamId :: es_contract_event:stream_id(),
    AggregateType :: es_contract_event:aggregate_type(),
    Type :: es_contract_event:type(),
    Seq :: es_contract_event:sequence(),
    Tags :: es_contract_event:tags(),
    Timestamp :: non_neg_integer(),
    Metadata :: es_contract_event:metadata(),
    Payload :: es_contract_event:payload()
) ->
    es_contract_event:t().
new_event(StreamId, AggregateType, Type, Sequence, Tags, Timestamp, Metadata, Payload) ->
    Event0 = es_contract_event:new(
        AggregateType,
        Type,
        StreamId,
        Sequence,
        Metadata#{timestamp => Timestamp},
        Payload
    ),
    es_contract_event:with_tags(Tags, Event0).

-doc """
Creates a new event, defaulting tags to `[]` and metadata to `#{}`.
""".
-spec new_event(
    StreamId :: es_contract_event:stream_id(),
    AggregateType :: es_contract_event:aggregate_type(),
    Type :: es_contract_event:type(),
    Sequence :: es_contract_event:sequence(),
    Timestamp :: non_neg_integer(),
    Payload :: es_contract_event:payload()
) ->
    es_contract_event:t().
new_event(StreamId, AggregateType, Type, Sequence, Timestamp, Payload) ->
    new_event(StreamId, AggregateType, Type, Sequence, [], Timestamp, #{}, Payload).

-doc """
Returns the unique identifier of the event as `{AggregateType, StreamId, Sequence}`.
""".
-spec id(Event :: es_contract_event:t()) -> es_contract_event:key().
id(Event) ->
    es_contract_event:key(Event).

-doc """
Returns the event aggregate type.
""".
-spec aggregate_type(es_contract_event:t()) -> es_contract_event:aggregate_type().
aggregate_type(Event) ->
    maps:get(aggregate_type, Event).

-doc """
Returns the event type.
""".
-spec type(es_contract_event:t()) -> es_contract_event:type().
type(Event) ->
    maps:get(type, Event).

-doc """
Returns the identifier of the event stream to which this event belongs.
""".
-spec stream_id(es_contract_event:t()) -> es_contract_event:stream_id().
stream_id(Event) ->
    maps:get(stream_id, Event).

-doc """
Returns the sequence number of this event within its stream.
""".
-spec sequence(es_contract_event:t()) -> es_contract_event:sequence().
sequence(Event) ->
    maps:get(sequence, Event).

-doc """
Retrieves a list of tags associated with this event.
""".
-spec tags(es_contract_event:t()) -> es_contract_event:tags().
tags(Event) ->
    maps:get(tags, Event).

-doc """
Returns the timestamp marking when this event occurred. The timestamp is stored
in the event metadata under the `timestamp` key.
""".
-spec timestamp(es_contract_event:t()) -> non_neg_integer().
timestamp(Event) ->
    maps:get(timestamp, metadata(Event)).

-doc """
Retrieves arbitrary metadata associated with this event.
""".
-spec metadata(es_contract_event:t()) -> es_contract_event:metadata().
metadata(Event) ->
    maps:get(metadata, Event).

-doc """
Retrieves the payload containing the domain-specific data of this event.
""".
-spec payload(es_contract_event:t()) -> es_contract_event:payload().
payload(Event) ->
    maps:get(payload, Event).

-doc """
Creates a new snapshot record.

- AggregateType is the aggregate type (aggregate module) to which the stream belongs.
- StreamId is the unique identifier for the stream.
- Sequence is the sequence number of the last event included in the snapshot.
- Timestamp is the timestamp when the snapshot was created.
- State is the aggregate state to snapshot.

The timestamp is stored inside the snapshot metadata under the `timestamp` key.
""".
-spec new_snapshot(AggregateType, StreamId, Sequence, Timestamp, State) -> Snapshot when
    AggregateType :: es_contract_event:aggregate_type(),
    StreamId :: es_contract_event:stream_id(),
    Sequence :: es_contract_event:sequence(),
    Timestamp :: non_neg_integer(),
    State :: es_contract_snapshot:state(),
    Snapshot :: es_contract_snapshot:t().
new_snapshot(AggregateType, StreamId, Sequence, Timestamp, State) ->
    Metadata = #{timestamp => Timestamp},
    es_contract_snapshot:new(AggregateType, StreamId, Sequence, Metadata, State).

-doc """
Stores a snapshot using the specified store module.

This function delegates snapshot storage to the backend implementation. The snapshot
captures aggregate state at a specific sequence number, enabling faster rehydration
by avoiding full event replay from the stream's beginning.

The snapshot map contains all necessary information (domain, stream_id, sequence,
metadata, state), consistent with event persistence where complete records are
passed rather than individual fields. The timestamp is available inside the metadata.

Returns `ok` on success, or `{warning, Reason}` if persistence fails. Warnings are
preferred over exceptions since snapshots are optimizations, not requirements.
""".
-spec store(StoreContext, Snapshot) -> ok | {warning, Reason} when
    StoreContext :: store_context(),
    Snapshot :: es_contract_snapshot:t(),
    Reason :: term().
store({_, SnapshotModule}, Snapshot) ->
    SnapshotModule:store(Snapshot).

-doc """
Loads the latest snapshot for a stream using the specified store module.

Returns `{ok, Snapshot}` if found, `{error, not_found}` otherwise. This enables
fast aggregate rehydration by restoring state from the snapshot and replaying only
events that occurred after the snapshot's sequence number.
""".
-spec load_latest(StoreContext, StreamId) -> {ok, Snapshot} | {error, not_found} when
    StoreContext :: store_context(),
    StreamId :: es_contract_event:stream_id(),
    Snapshot :: es_contract_snapshot:t().
load_latest({_, SnapshotModule}, StreamId) ->
    SnapshotModule:load_latest(StreamId).

-doc """
Returns the stream identifier of the snapshot.
""".
-spec snapshot_stream_id(es_contract_snapshot:t()) -> es_contract_event:stream_id().
snapshot_stream_id(Snapshot) ->
    maps:get(stream_id, Snapshot).

-doc """
Returns the aggregate type of the snapshot.
""".
-spec snapshot_aggregate_type(es_contract_snapshot:t()) -> es_contract_event:aggregate_type().
snapshot_aggregate_type(Snapshot) ->
    maps:get(aggregate_type, Snapshot).

-doc """
Returns the sequence number of the snapshot (last event included).
""".
-spec snapshot_sequence(es_contract_snapshot:t()) -> es_contract_event:sequence().
snapshot_sequence(Snapshot) ->
    maps:get(sequence, Snapshot).

-doc """
Returns the timestamp when the snapshot was created.
""".
-spec snapshot_timestamp(es_contract_snapshot:t()) -> non_neg_integer().
snapshot_timestamp(Snapshot) ->
    maps:get(timestamp, maps:get(metadata, Snapshot)).

-doc """
Returns the state stored in the snapshot.
""".
-spec snapshot_state(es_contract_snapshot:t()) -> es_contract_snapshot:state().
snapshot_state(Snapshot) ->
    maps:get(state, Snapshot).
