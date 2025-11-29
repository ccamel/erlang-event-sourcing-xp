-module(es_contract_event).

-export([
    new/6,
    key/1,
    with_metadata/2,
    put_metadata/3,
    with_tags/2,
    add_tag/2,
    map_payload/2
]).

-export_type([
    aggregate_type/0,
    stream_id/0,
    sequence/0,
    type/0,
    metadata_key/0,
    metadata_value/0,
    metadata/0,
    tag/0,
    tags/0,
    payload/0,
    t/0,
    key/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-doc "Aggregate type identifier, specifying which kind of aggregate this event belongs to.".
-type aggregate_type() :: atom().

-doc """
Aggregate identifier, uniquely identifying an aggregate instance.

Can be any term (UUID, binary, integer, etc.).
""".
-type aggregate_id() :: term().

-doc """
Stream identifier, uniquely identifying an event stream.

A stream is identified by a tuple of {AggregateType, AggregateId}, ensuring no collisions
across different aggregate types and instances.
""".
-type stream_id() :: {aggregate_type(), aggregate_id()}.

-doc "Sequence number of the event within its stream, starting from 0.".
-type sequence() :: non_neg_integer().

-doc "Type identifier for the event, describing what happened.".
-type type() :: atom() | binary().

-doc "Metadata map containing contextual information about the event.".
-type metadata_key() :: atom() | binary().
-type metadata_value() :: term().
-type metadata() :: #{metadata_key() => metadata_value()}.

-doc "Tag for categorizing events.".
-type tag() :: binary().

-doc "List of tags associated with an event.".
-type tags() :: [tag()].

-doc """
Event payload containing the event-specific data.

The payload is the actual domain data that describes what changed in the system.
""".
-type payload() :: term().

-doc """
Event data structure.

An event represents a fact that something has happened in the system. It consists of:
- `aggregate_type`: The aggregate type this event belongs to
- `type`: The type of event that occurred
- `stream_id`: Identifier of the stream this event belongs to
- `sequence`: Position of this event in the stream (0-based)
- `metadata`: Additional contextual information (timestamp, user, etc.)
- `tags`: Labels for categorization or routing
- `payload`: The actual event data describing what changed
""".
-type t() :: #{
    aggregate_type := aggregate_type(),
    type := type(),
    stream_id := stream_id(),
    sequence := sequence(),
    metadata := metadata(),
    tags := tags(),
    payload := payload()
}.

-doc """
Composite key uniquely identifying an event.

The key is a tuple of the StreamId and the Sequence that uniquely identifies
an event within the entire event store.
""".
-type key() :: {stream_id(), sequence()}.

%%--------------------------------------------------------------------
%% Functions
%%--------------------------------------------------------------------

-spec new(aggregate_type(), type(), stream_id(), sequence(), metadata(), payload()) -> t().
new(AggregateType, Type, StreamId, Sequence, Metadata, Payload) ->
    #{
        aggregate_type => AggregateType,
        type => Type,
        stream_id => StreamId,
        sequence => Sequence,
        metadata => Metadata,
        tags => [],
        payload => Payload
    }.

-spec key(t()) -> key().
key(#{stream_id := S, sequence := Seq}) ->
    {S, Seq}.

-spec with_metadata(metadata(), t()) -> t().
with_metadata(Meta, Event) when is_map(Event) ->
    Event#{metadata := Meta}.

-spec put_metadata(metadata_key(), metadata_value(), t()) -> t().
put_metadata(Key, Value, #{metadata := Meta} = Event) ->
    Event#{metadata := Meta#{Key => Value}}.

-spec with_tags(tags(), t()) -> t().
with_tags(Tags, Event) when is_map(Event) ->
    Event#{tags := Tags}.

-spec add_tag(tag(), t()) -> t().
add_tag(Tag, #{tags := Tags} = Event) ->
    Event#{tags := [Tag | Tags]}.

-spec map_payload(fun((payload()) -> payload()), t()) -> t().
map_payload(Fun, #{payload := Payload} = Event) ->
    Event#{payload := Fun(Payload)}.
