%% @doc
%% This module defines a behavior for an event sourcing event store.
%% Event sourcing is a design pattern where application state is derived by replaying
%% a sequence of immutable events. This behavior provides a standardized behaviour
%% for persisting events to a stream and retrieving them for state reconstruction.
%%
%% Implementing modules (e.g., an in-memory store or database-backed store) must
%% provide the callbacks defined here. The module also exports utility functions
%% to interact with the store and access event record fields.
-module(event_sourcing_store).

-export([start/1, stop/1, persist_event/2, retrieve_and_fold_events/5, retrieve_events/3,
         id/1, domain/1, type/1, stream_id/1, sequence/1, timestamp/1, tags/1, metadata/1,
         payload/1, new_event/8, new_event/6]).

-export_type([id/0,event/0, stream_id/0, payload/0, sequence/0, fold_events_opts/0,
              fold_events_fun/0, acc/0, domain/0, type/0, tags/0, metadata/0, timestamp/0,
              store/0]).

%% @doc
%% Starts the event store, performing any necessary initialization.
%%
%% This callback is called to prepare the store for operation (e.g., setting up
%% database connections, initializing in-memory structures). Implementations
%% should be idempotent, allowing repeated calls without side effects.
%%
%% @returns
%% - `{ok, initialized}` if the store was successfully initialized for the first time.
%% - `{ok, already_initialized}` if the store was already running.
%% - `{error, Reason}` if initialization failed, where `Reason` describes the failure
%%   (e.g., `db_connection_failed`).
-callback start() -> {ok, initialized | already_initialized} | {error, term()}.
%% @doc
%% This callback function is used to stop the event store.
%%
%% The callback should perform any necessary cleanup of the event store.
%%
%% It should return either {ok} if the stop operation was successful,
%% or {error, Reason} if there was an error, where `Reason` is a term
%% describing the error.
-callback stop() -> {ok} | {error, term()}.
%% @doc
%% Persists a single event to the specified event stream.
%%
%% This callback appends an event to the stream identified by `StreamId`. The `Sequence`
%% must be the next expected sequence in the stream to ensure event ordering and
%% prevent conflicts. The `Payload` contains domain-specific event data.
%%
%% @param Event The event to persist.
%%
%% @returns
%% - `ok` if the event was persisted.
%% - `{error, Reason}` if persistence failed (e.g., `sequence_conflict` if the sequence
%%   does not match the expected next sequence).
-callback persist_event(Event) -> ok | {error, term()} when Event :: event().
%% @doc
%% Retrieves events from a stream and folds them into an accumulator.
%%
%% This callback fetches events for the given `StreamId`, applies the `FoldFun` to each
%% event in sequence order, and returns the final accumulator. It’s typically used to
%% rebuild application state by replaying events.
%%
%% @param StreamId A string identifying the event stream (e.g., "order-123").
%% @param Options A list of filters:
%%   - `{from, Sequence}`: Start at this sequence (default: 0).
%%   - `{to, Sequence | infinity}`: End at this sequence (default: infinity).
%%   - `{limit, Limit}`: Maximum number of events to retrieve (default: infinity).
%% @param FoldFun A function `fun((EventRecord, Acc) -> NewAcc)` to process each event.
%% @param InitialAcc The initial accumulator value (e.g., an empty state).
%%
%% @returns
%% - `{ok, Acc}` where `Acc` is the result of folding all events.
%% - `{error, Reason}` if retrieval fails (e.g., `stream_not_found`).
-callback retrieve_and_fold_events(StreamId, Options, FoldFun, InitialAcc) ->
                                      {ok, Acc} | {error, term()}
    when StreamId :: stream_id(),
         Options :: fold_events_opts(),
         FoldFun :: fold_events_fun(),
         InitialAcc :: Acc.

-spec start(store()) -> {ok, initialized | already_initialized} | {error, term()}.
start(Module) ->
    Module:start().

-spec stop(store()) -> {ok} | {error, term()}.
stop(Module) ->
    Module:stop().

%% @doc
%% Persists a event in the event store using the specified persistence module.
-spec persist_event(StoreModule :: store(), Event :: event()) -> ok | {error, term()}.
persist_event(StoreModule, Event) ->
    StoreModule:persist_event(Event).

%% @doc
%% Retrieves and folds events from the event store using the specified persistence module.
-spec retrieve_and_fold_events(store(),
                               stream_id(),
                               fold_events_opts(),
                               fold_events_fun(),
                               acc()) ->
                                  {ok, acc()} | {error, term()}.
retrieve_and_fold_events(StoreModule, StreamId, Options, Fun, InitialAcc) ->
    StoreModule:retrieve_and_fold_events(StreamId, Options, Fun, InitialAcc).

%% @doc
%% Retrieves events for a given stream using the specified store module and options.
-spec retrieve_events(store(), stream_id(), fold_events_opts()) ->
                         {ok, [event()]} | {error, term()}.
retrieve_events(StoreModule, StreamId, Options) ->
    retrieve_and_fold_events(StoreModule,
                             StreamId,
                             Options,
                             fun(Event, Acc) -> Acc ++ [Event] end,
                             []).

-type id() :: {domain(), stream_id(), sequence()}.
-type stream_id() :: string().
-type domain() :: atom().
-type type() :: atom().
-type sequence() :: non_neg_integer().
-type tags() :: [string()].
-type timestamp() :: calendar:datetime().
-type metadata() :: #{string() => string()}.
-type payload() :: tuple().
-type fold_events_opts() ::
    [{from, non_neg_integer()} |
     {to, non_neg_integer() | infinity} |
     {limit, pos_integer() | infinity}].
-type fold_events_fun() :: fun((event(), acc()) -> acc()).
-type acc() :: any().
-type store() :: module().

%% @doc
%% Internal structure for events
-record(event,
        {stream_id :: stream_id(),
         domain :: domain(),
         type :: type(),
         sequence :: sequence(),
         tags = [] :: tags(),
         timestamp :: timestamp(),
         metadata = #{} :: metadata(),
         payload :: payload()}).

%% @doc
%% Represents a single persisted event in the event sourcing system.
%%
%% An event is an immutable record of a domain change, belonging to a specific stream.
%% It includes metadata, a timestamp, and a payload with domain-specific data. This
%% opaque type is used internally by the store and returned by `retrieve_and_fold_events/4`.
%%
%% Fields:
%% - `stream_id`: Stream identifier (e.g., "user-001").
%% - `domain` : Domain name (e.g., "user").
%% - `type`: Event type (e.g., "user_registered").
%% - `sequence`: Event sequence within the stream (e.g., 1).
%% - `tags`: List of strings for categorization (e.g., ["auth", "signup"]).
%% - `timestamp`: UTC datetime of occurrence (e.g., {{2025, 3, 16}, {12, 0, 0}}).
%% - `metadata`: Key-value map of additional info (e.g., #{"user_agent" => "firefox"}).
%% - `payload`: Domain-specific data as a tuple (e.g., `{user_registered, <<"john doe">>}`).
-opaque event() ::
    #event{stream_id :: stream_id(),
                  domain :: domain(),
                  type :: type(),
                  sequence :: sequence(),
                  tags :: tags(),
                  timestamp :: timestamp(),
                  metadata :: metadata(),
                  payload :: payload()}.

%% @doc
%% Creates a new event.
%%
%% @param StreamId The unique identifier for the stream.
%% @param Domain The domain to which the event belongs.
%% @param Type The type of the event.
%% @param Sequence The sequence number of the event in the stream.
%% @param Tags A list of tags associated with the event.
%% @param Timestamp The timestamp when the event occurred.
%% @param Metadata Additional metadata for the event.
%% @param Payload The actual data of the event.
%%
%% @return The created event.
-spec new_event(StreamId :: stream_id(),
                Domain :: domain(),
                Type :: type(),
                Sequence :: sequence(),
                Tags :: tags(),
                Timestamp :: timestamp(),
                Metadata :: metadata(),
                Payload :: payload()) ->
                   event().
new_event(StreamId, Domain, Type, Sequence, Tags, Timestamp, Metadata, Payload) ->
    #event{stream_id = StreamId,
                  domain = Domain,
                  type = Type,
                  sequence = Sequence,
                  tags = Tags,
                  timestamp = Timestamp,
                  metadata = Metadata,
                  payload = Payload}.

%% @doc
%% Creates a new event.
%%
%% @param StreamId The unique identifier for the stream.
%% @param Domain The domain to which the event belongs.
%% @param Type The type of the event.
%% @param Sequence The sequence number of the event in the stream.
%% @param Timestamp The timestamp when the event occurred.
%% @param Payload The actual data of the event.
%%
%% @return The created event.
-spec new_event(StreamId :: stream_id(),
                Domain :: domain(),
                Type :: type(),
                Sequence :: sequence(),
                Timestamp :: timestamp(),
                Payload :: payload()) ->
                   event().
new_event(StreamId, Domain, Type, Sequence, Timestamp, Payload) ->
    new_event(StreamId, Domain, Type, Sequence, [], Timestamp, #{}, Payload).

%% @doc
%% Returns the unique identifier of the event.
%% The identifier is a string composed of the domain, the stream id and sequence number.
-spec id(Event :: event()) -> id().
id(#event{domain = Domain,
                 stream_id = StreamId,
                 sequence = Sequence}) ->
    {Domain, StreamId, Sequence}.

%% @doc
%% Returns the event domain, representing the domain context that generated the event.
-spec domain(event()) -> domain().
domain(#event{domain = Domain}) ->
    Domain.

%% @doc
%% Returns the event type, representing the specific event that occurred.
-spec type(event()) -> type().
type(#event{type = Type}) ->
    Type.

%% @doc
%% Returns the identifier of the event stream to which this event belongs.
-spec stream_id(event()) -> stream_id().
stream_id(#event{stream_id = StreamId}) ->
    StreamId.

%% @doc
%% Returns the sequence number of this event within its stream.
-spec sequence(event()) -> sequence().
sequence(#event{sequence = Sequence}) ->
    Sequence.

%% @doc
%% Retrieves a list of tags associated with this event. Tags can be used for
%% categorization, filtering, or indexing.
-spec tags(event()) -> tags().
tags(#event{tags = Tags}) ->
    Tags.

%% @doc
%% Returns the timestamp marking when this event occurred (UTC).
-spec timestamp(event()) -> timestamp().
timestamp(#event{timestamp = Timestamp}) ->
    Timestamp.

%% @doc
%% Retrieves arbitrary metadata associated with this event. Metadata typically
%% includes contextual information.
-spec metadata(event()) -> metadata().
metadata(#event{metadata = Metadata}) ->
    Metadata.

%% @doc
%% Retrieves the payload containing the domain-specific data of this event.
-spec payload(event()) -> payload().
payload(#event{payload = Payload}) ->
    Payload.
