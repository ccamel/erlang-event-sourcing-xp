-module(es_contract_snapshot).

-export([
    new/5,
    key/1,
    with_metadata/2,
    put_metadata/3,
    map_state/2
]).

-export_type([
    domain/0,
    stream_id/0,
    sequence/0,
    metadata_key/0,
    metadata_value/0,
    metadata/0,
    state/0,
    t/0,
    key/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-doc "Domain identifier, representing a bounded context.".
-type domain() :: atom().

-doc "Stream identifier, uniquely identifying an event stream within a domain.".
-type stream_id() :: binary().

-doc "Sequence number of the event within its stream, starting from 0.".
-type sequence() :: non_neg_integer().

-doc "Metadata map containing contextual information about the event.".
-type metadata_key() :: atom() | binary().
-type metadata_value() :: term().
-type metadata() :: #{metadata_key() => metadata_value()}.

-doc "Aggregate state captured by the snapshot. Opaque to the kernel.".
-type state() :: term().

-doc """
Snapshot data structure.
A snapshot represents a point-in-time capture of an aggregate's state. It consists of:
- `domain`: The domain this snapshot belongs to
- `stream_id`: Identifier of the stream this snapshot is for
- `sequence`: Position in the event stream up to which the snapshot reflects
- `metadata`: Additional contextual information (timestamp, etc.)
- `state`: The actual aggregate state at that point in time
""".
-type t() :: #{
    domain := domain(),
    stream_id := stream_id(),
    sequence := sequence(),
    metadata := metadata(),
    state := state()
}.

-doc """
Composite key uniquely identifying a snapshot.
The key is a tuple of the Domain, the StreamId and the Sequence that uniquely identifies
a snapshot within the entire snapshot store.
""".
-type key() :: {domain(), stream_id(), sequence()}.

%%--------------------------------------------------------------------
%% Functions
%%--------------------------------------------------------------------

-spec new(domain(), stream_id(), sequence(), metadata(), state()) -> t().
new(Domain, StreamId, Sequence, Metadata, State) ->
    #{
        domain => Domain,
        stream_id => StreamId,
        sequence => Sequence,
        metadata => Metadata,
        state => State
    }.

-spec key(t()) -> key().
key(#{domain := D, stream_id := S, sequence := Seq}) ->
    {D, S, Seq}.

-spec with_metadata(metadata(), t()) -> t().
with_metadata(Meta, Snap) when is_map(Snap) ->
    Snap#{metadata := Meta}.

-spec put_metadata(metadata_key(), metadata_value(), t()) -> t().
put_metadata(Key, Value, Snap) when is_map(Snap) ->
    Meta = maps:get(metadata, Snap),
    Snap#{metadata := Meta#{Key => Value}}.

-spec map_state(fun((state()) -> state()), t()) -> t().
map_state(Fun, Snap) when is_map(Snap) ->
    State = maps:get(state, Snap),
    Snap#{state := Fun(State)}.
