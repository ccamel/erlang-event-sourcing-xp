-module(event_sourcing_core_store).
-moduledoc """
This module defines a behavior for an event sourcing event store.

Event sourcing is a design pattern where application state is derived by replaying
a sequence of immutable events. This behavior provides a standardized behaviour
for persisting events to a stream and retrieving them for state reconstruction.
Implementing modules (e.g., an in-memory store or database-backed store) must
provide the callbacks defined here. The module also exports utility functions
to interact with the store and access event record fields.
""".

-include_lib("event_sourcing_core.hrl").

-export([
    start/1,
    stop/1,
    persist_events/3,
    retrieve_and_fold_events/5,
    retrieve_events/3,
    id/1,
    domain/1,
    type/1,
    stream_id/1,
    sequence/1,
    timestamp/1,
    tags/1,
    metadata/1,
    payload/1,
    new_event/8, new_event/6
]).

-export_type([
    fold_events_opts/0,
    domain/0,
    event/0,
    event_id/0,
    event_payload/0,
    event_type/0,
    metadata/0,
    sequence/0,
    stream_id/0,
    tags/0,
    timestamp/0
]).

-doc """
Starts the event store, performing any necessary initialization.

This callback is called to prepare the store for operation (e.g., setting up
database connections, initializing in-memory structures). Implementations
should be idempotent, allowing repeated calls without side effects.

Returns `ok` on success. May throw an exception if initialization fails
(e.g., resource unavailable).
""".
-callback start() -> ok.
-doc """
This callback function is used to stop the event store.

The callback should perform any necessary cleanup of the event store.
The function should be idempotent, allowing repeated calls without side effects.

Returns `ok` on success. May throw an exception if cleanup fails
(e.g., resource not found).
""".
-callback stop() -> ok.
-doc """
Append events to an event stream.

This callback appends events to the specified streams.

- StreamId is an atom identifying the event stream (e.g., order-123).
- Events is the list of events to append to the stream. The events provided are unique and all
belong to the same stream.

Returns `ok` on success. May throw an exception if persistence fails (e.g., badarg if the
stream ID is incorrect, duplicate events if the sequence number is not unique).
""".
-callback persist_events(StreamId, Events) -> ok when
    StreamId :: stream_id(),
    Events :: [event()].
-doc """
Retrieves events from a stream and folds them into an accumulator.

This callback fetches events for the given `StreamId`, applies the `FoldFun` to each
event in sequence order, and returns the final accumulator. It’s typically used to
rebuild application state by replaying events.

- StreamId is an atom identifying the event stream (e.g., order-123).
- Options is A list of filters:
  - `{from, Sequence}`: Start at this sequence (default: 0).
  - `{to, Sequence | infinity}`: End at this sequence (default: infinity).
  - `{limit, Limit}`: Maximum number of events to retrieve (default: infinity).
- FoldFun is a function `fun((Event, AccIn) -> AccOut)` to process each event.
- InitialAcc is The initial accumulator value (e.g., an empty state).

Returns `{ok, Acc}` where `Acc` is the result of folding all events.
""".
-callback retrieve_and_fold_events(StreamId, Options, Fun, Acc0) -> Acc1 when
    StreamId :: stream_id(),
    Options :: fold_events_opts(),
    Fun :: fun((Event :: event(), AccIn) -> AccOut),
    Acc0 :: term(),
    Acc1 :: term(),
    AccIn :: term(),
    AccOut :: term().

-spec start(module()) -> ok.
start(Module) ->
    Module:start().

-spec stop(module()) -> ok.
stop(Module) ->
    Module:stop().

-doc """
Persists a event in the event store using the specified persistence module.
""".
-spec persist_events(StoreModule, StreamId, Events) -> ok when
    StoreModule :: module(),
    StreamId :: stream_id(),
    Events :: [event()].
persist_events(StoreModule, StreamId, Events) when is_list(Events) ->
    _ = lists:foldl(
        fun(Event, Seen) ->
            case stream_id(Event) of
                StreamId ->
                    Id = id(Event),
                    case lists:member(Id, Seen) of
                        true ->
                            erlang:error(duplicate_event);
                        false ->
                            [Id | Seen]
                    end;
                WrongStreamId ->
                    erlang:error({badarg, WrongStreamId})
            end
        end,
        [],
        Events
    ),
    StoreModule:persist_events(StreamId, Events).

-doc """
Retrieves and folds events from the event store using the specified persistence module.
""".
-spec retrieve_and_fold_events(StoreModule, StreamId, Options, Fun, Acc0) -> Acc1 when
    StoreModule :: module(),
    StreamId :: stream_id(),
    Options :: fold_events_opts(),
    Fun :: fun((Event :: event(), AccIn) -> AccOut),
    Acc0 :: term(),
    Acc1 :: term(),
    AccIn :: term(),
    AccOut :: term().
retrieve_and_fold_events(StoreModule, StreamId, Options, Fun, InitialResult) ->
    StoreModule:retrieve_and_fold_events(StreamId, Options, Fun, InitialResult).

-doc """
Retrieves events for a given stream using the specified store module and options.
""".
-spec retrieve_events(StoreModule, StreamId, Options) -> Result when
    StoreModule :: module(),
    StreamId :: stream_id(),
    Options :: fold_events_opts(),
    Result :: [event()].
retrieve_events(StoreModule, StreamId, Options) ->
    retrieve_and_fold_events(
        StoreModule,
        StreamId,
        Options,
        fun(Event, Acc) -> Acc ++ [Event] end,
        []
    ).

-type fold_events_opts() ::
    #{
        from => non_neg_integer(),
        to => non_neg_integer() | infinity,
        limit => pos_integer() | infinity
    }.

-doc """
Creates a new event.

- StreamId is the unique identifier for the stream.
- Domain is the domain to which the event belongs.
- Type is the type of the event.
- Sequence is the sequence number of the event in the stream.
- Tags is a list of tags associated with the event.
- Timestamp is the timestamp when the event occurred.
- Metadata is the additional metadata for the event.
- Payload is the actual data of the event.

Returns the created event.
""".
-spec new_event(
    StreamId :: stream_id(),
    Domain :: domain(),
    Type :: event_type(),
    Seq :: sequence(),
    Tags :: tags(),
    Timestamp :: timestamp(),
    Metadata :: metadata(),
    Payload :: event_payload()
) ->
    event().
new_event(StreamId, Domain, Type, Sequence, Tags, Timestamp, Metadata, Payload) ->
    #event{
        stream_id = StreamId,
        domain = Domain,
        type = Type,
        sequence = Sequence,
        tags = Tags,
        timestamp = Timestamp,
        metadata = Metadata,
        payload = Payload
    }.

-doc """
Creates a new event.

- StreamId is the unique identifier for the stream.
- Domain is the domain to which the event belongs.
- Type is the type of the event.
- Sequence is the sequence number of the event in the stream.
- Timestamp is the timestamp when the event occurred.
- Payload is the actual data of the event.

@return The created event.
""".
-spec new_event(
    StreamId :: stream_id(),
    Domain :: domain(),
    Type :: event_type(),
    Sequence :: sequence(),
    Timestamp :: timestamp(),
    Payload :: event_payload()
) ->
    event().
new_event(StreamId, Domain, Type, Sequence, Timestamp, Payload) ->
    new_event(StreamId, Domain, Type, Sequence, [], Timestamp, #{}, Payload).

-doc """
Returns the unique identifier of the event.
The identifier is a string composed of the domain, the stream id and sequence number.
""".
-spec id(Event :: event()) -> event_id().
id(#event{
    domain = Domain,
    stream_id = StreamId,
    sequence = Sequence
}) ->
    {Domain, StreamId, Sequence}.

-doc """
Returns the event domain, representing the domain context that generated the event.
""".
-spec domain(event()) -> domain().
domain(#event{domain = Domain}) ->
    Domain.

-doc """
Returns the event type, representing the specific event that occurred.
""".
-spec type(event()) -> event_type().
type(#event{type = Type}) ->
    Type.

-doc """
Returns the identifier of the event stream to which this event belongs.
""".
-spec stream_id(event()) -> stream_id().
stream_id(#event{stream_id = StreamId}) ->
    StreamId.

-doc """
Returns the sequence number of this event within its stream.
""".
-spec sequence(event()) -> sequence().
sequence(#event{sequence = Sequence}) ->
    Sequence.

-doc """
Retrieves a list of tags associated with this event. Tags can be used for
categorization, filtering, or indexing.
""".
-spec tags(event()) -> tags().
tags(#event{tags = Tags}) ->
    Tags.

-doc """
Returns the timestamp marking when this event occurred (UTC).
""".
-spec timestamp(event()) -> timestamp().
timestamp(#event{timestamp = Timestamp}) ->
    Timestamp.

-doc """
Retrieves arbitrary metadata associated with this event. Metadata typically
includes contextual information.
""".
-spec metadata(event()) -> metadata().
metadata(#event{metadata = Metadata}) ->
    Metadata.

-doc """
Retrieves the payload containing the domain-specific data of this event.
""".
-spec payload(event()) -> event_payload().
payload(#event{payload = Payload}) ->
    Payload.
