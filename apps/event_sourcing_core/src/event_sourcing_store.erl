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

-export([start/1, stop/1, persist_event/4, retrieve_and_fold_events/5, retrieve_events/3,
         id/1, type/1, stream_id/1, version/1, timestamp/1, tags/1, metadata/1, payload/1]).

-export_type([event_record/0, stream_id/0, payload/0, version/0, options/0, fold_fun/0,
              acc/0, id/0, type/0, tags/0, metadata/0, timestamp/0, store/0]).

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
%% This callback appends an event to the stream identified by `StreamId`. The `Version`
%% must be the next expected version in the stream to ensure event ordering and
%% prevent conflicts. The `Payload` contains domain-specific event data.
%%
%% @param StreamId A unique string identifying the event stream (e.g., "order-123").
%% @param Version A non-negative integer representing the event’s position in the stream.
%% @param Payload A tuple containing the event’s domain data (e.g., `{order_created, 42}`).
%%
%% @returns
%% - `{ok, Id}` if the event was persisted, where `Id` is the unique event identifier.
%% - `{error, Reason}` if persistence failed (e.g., `version_conflict` if the version
%%   does not match the expected next version).
-callback persist_event(StreamId, Version, Payload) -> {ok, id()} | {error, term()}
    when StreamId :: stream_id(),
         Version :: version(),
         Payload :: payload().
%% @doc
%% Retrieves events from a stream and folds them into an accumulator.
%%
%% This callback fetches events for the given `StreamId`, applies the `FoldFun` to each
%% event in version order, and returns the final accumulator. It’s typically used to
%% rebuild application state by replaying events.
%%
%% @param StreamId A string identifying the event stream (e.g., "order-123").
%% @param Options A list of filters:
%%   - `{from, Version}`: Start at this version (default: 0).
%%   - `{to, Version | infinity}`: End at this version (default: infinity).
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
         Options :: options(),
         FoldFun :: fold_fun(),
         InitialAcc :: Acc.

-spec start(store()) -> {ok, initialized | already_initialized} | {error, term()}.
start(Module) ->
    Module:start().

-spec stop(store()) -> {ok} | {error, term()}.
stop(Module) ->
    Module:stop().

%% @doc
%% Persists an event in the event store using the specified persistence module.
-spec persist_event(store(), stream_id(), version(), payload()) ->
                       {ok, id()} | {error, term()}.
persist_event(Module, StreamId, Version, Payload) ->
    Module:persist_event(StreamId, Version, Payload).

%% @doc
%% Retrieves and folds events from the event store using the specified persistence module.
-spec retrieve_and_fold_events(store(), stream_id(), options(), fold_fun(), acc()) ->
                                  {ok, acc()} | {error, term()}.
retrieve_and_fold_events(StoreModule, StreamId, Options, Fun, InitialAcc) ->
    StoreModule:retrieve_and_fold_events(StreamId, Options, Fun, InitialAcc).

%% @doc
%% Retrieves events for a given stream using the specified store module and options.
-spec retrieve_events(store(), stream_id(), options()) ->
                         {ok, [event_record()]} | {error, term()}.
retrieve_events(StoreModule, StreamId, Options) ->
    retrieve_and_fold_events(StoreModule,
                             StreamId,
                             Options,
                             fun(Event, Acc) -> Acc ++ [Event] end,
                             []).

-type id() :: string().
-type type() :: string().
-type stream_id() :: string().
-type version() :: non_neg_integer().
-type tags() :: [string()].
-type timestamp() :: calendar:datetime().
-type metadata() :: #{string() => string()}.
-type payload() :: tuple().
-type options() ::
    [{from, non_neg_integer()} |
     {to, non_neg_integer() | infinity} |
     {limit, pos_integer() | infinity}].
-type fold_fun() :: fun((event_record(), acc()) -> acc()).
-type acc() :: any().
-type store() :: module().

%% @doc
%% Internal structure for events
-record(event_record,
        {id :: id(),
         type :: type(),
         stream_id :: stream_id(),
         version :: version(),
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
%% - `id`: Unique event identifier (e.g., "evt-xyz123").
%% - `type`: Event type (e.g., "user_registered").
%% - `stream_id`: Stream identifier (e.g., "user-001").
%% - `version`: Event version within the stream (e.g., 1).
%% - `tags`: List of strings for categorization (e.g., ["auth", "signup"]).
%% - `timestamp`: UTC datetime of occurrence (e.g., {{2025, 3, 16}, {12, 0, 0}}).
%% - `metadata`: Key-value map of additional info (e.g., #{"user_agent" => "firefox"}).
%% - `payload`: Domain-specific data as a tuple (e.g., `{user_registered, <<"john doe">>}`).
-opaque event_record() ::
    #event_record{id :: id(),
                  type :: type(),
                  stream_id :: stream_id(),
                  version :: version(),
                  tags :: tags(),
                  timestamp :: timestamp(),
                  metadata :: metadata(),
                  payload :: payload()}.

%% @doc
%% Returns the unique identifier (`id`) of the event.
-spec id(event_record()) -> id().
id(#event_record{id = Id}) ->
    Id.

%% @doc
%% Returns the event type, representing the domain action or occurrence captured by the event.
-spec type(event_record()) -> type().
type(#event_record{type = Type}) ->
    Type.

%% @doc
%% Returns the identifier of the event stream to which this event belongs.
-spec stream_id(event_record()) -> stream_id().
stream_id(#event_record{stream_id = StreamId}) ->
    StreamId.

%% @doc
%% Returns the version number of this event within its stream.
-spec version(event_record()) -> version().
version(#event_record{version = Version}) ->
    Version.

%% @doc
%% Retrieves a list of tags associated with this event. Tags can be used for
%% categorization, filtering, or indexing.
-spec tags(event_record()) -> tags().
tags(#event_record{tags = Tags}) ->
    Tags.

%% @doc
%% Returns the timestamp marking when this event occurred (UTC).
-spec timestamp(event_record()) -> timestamp().
timestamp(#event_record{timestamp = Timestamp}) ->
    Timestamp.

%% @doc
%% Retrieves arbitrary metadata associated with this event. Metadata typically
%% includes contextual information.
-spec metadata(event_record()) -> metadata().
metadata(#event_record{metadata = Metadata}) ->
    Metadata.

%% @doc
%% Retrieves the payload containing the domain-specific data of this event.
-spec payload(event_record()) -> payload().
payload(#event_record{payload = Payload}) ->
    Payload.
