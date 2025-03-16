%% @doc
%% event_sourcing_event_store behaviour module.
-module(event_sourcing_store).

-export([id/1, type/1, stream_id/1, version/1, timestamp/1, tags/1, metadata/1,
         payload/1]).

-export_type([event_record/0, stream_id/0, payload/0, version/0, options/0, fold_fun/0,
              acc/0, id/0, type/0, tags/0, metadata/0, timestamp/0]).

%% @doc
%% This callback function is used to start the event store.
%%
%% The callback should perform any necessary initialization of the event store.
%%
%% It should return either {ok} if the stop operation was successful,
%% or {error, Reason} if there was an error, where `Reason` is a term
%% describing the error.
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
%% Callback function to persist an event in the event store.
%%
%% @param StreamId The unique identifier for the event stream.
%% @param Version The version of the event.
%% @param Payload The data associated with the event.
-callback persist_event(StreamId, Version, Payload) -> {ok, id()} | {error, term()}
    when StreamId :: stream_id(),
         Version :: version(),
         Payload :: payload().
%% @doc
%% Callback function to retrieve and fold events for a given stream ID.
%%
%% @param StreamId The ID of the event stream to retrieve events from.
%% @param Options A list of options to filter the events. The options are:
%%   - {from, non_neg_integer()} The version number to start retrieving events from.
%%     Defaults to 0.
%%   - {to, non_neg_integer()} The version number to stop retrieving events at.
%%     Defaults to infinity.
%% @param FoldFun A function to fold each event record into the accumulator.
%% @param InitialAcc The initial value of the accumulator.
%%
%% @return Result The result of folding the events sorted by version number.
-callback retrieve_and_fold_events(StreamId, Options, FoldFun, InitialAcc) ->
                                      {ok, Acc} | {error, term()}
    when StreamId :: stream_id(),
         Options :: options(),
         FoldFun :: fold_fun(),
         InitialAcc :: Acc.

-type id() :: string().
-type type() :: string().
-type stream_id() :: string().
-type version() :: non_neg_integer().
-type tags() :: [string()].
-type timestamp() :: calendar:datetime().
-type metadata() :: #{string() => string()}.
-type payload() :: tuple().
-type options() ::
    [{version_start, non_neg_integer()} | {version_end, non_neg_integer() | infinity}].
-type fold_fun() :: fun((event_record(), acc()) -> acc()).
-type acc() :: any().

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
%% Represents a persisted event in the event sourcing system.
%%
%% Each event captures a significant change or occurrence within a stream,
%% along with associated metadata, timestamp, and event-specific payload.
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
