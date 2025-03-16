-module(event_sourcing_core_persistence).

-include_lib("stdlib/include/qlc.hrl").

-export_type([event_record/0, id/0, type/0, stream_id/0, version/0, tags/0, timestamp/0,
              metadata/0, payload/0]).

-export([table_name/1, create_events_table/0, retrieve_and_fold_events/4,
         persist_event/3]).

-record(event_record,
        {id, type, stream_id, version, tags = [], timestamp, metadata = #{}, payload}).

-opaque event_record() ::
    #event_record{id :: id(),
                  type :: type(),
                  stream_id :: stream_id(),
                  version :: version(),
                  tags :: tags(),
                  timestamp :: timestamp(),
                  metadata :: metadata(),
                  payload :: payload()}.

-type id() :: string().
-type type() :: string().
-type stream_id() :: string().
-type version() :: non_neg_integer().
-type tags() :: [string()].
-type timestamp() :: calendar:datetime().
-type metadata() :: #{string() => string()}.
-type payload() :: tuple().

%% @doc The name of the table that will store events.
-define(EVENT_TABLE_NAME, events).

%% @doc The name of the tables used for persistence.
-spec table_name(events) -> events.
table_name(events) ->
    ?EVENT_TABLE_NAME.

%% @doc Create the events table if it doesn't exist.
-spec create_events_table() -> ok | {error, term()}.
create_events_table() ->
    try mnesia:table_info(?EVENT_TABLE_NAME, all) of
        _ ->
            ok
    catch
        exit:{aborted, {no_exists, ?EVENT_TABLE_NAME, all}} ->
            case mnesia:create_table(?EVENT_TABLE_NAME,
                                     [{attributes, record_info(fields, event_record)},
                                      {record_name, event_record},
                                      {type, set},
                                      {index, [type, stream_id, version]}])
            of
                {atomic, ok} ->
                    ok;
                {aborted, Reason} ->
                    {error, Reason}
            end
    end.

-spec persist_event(stream_id(), version(), payload()) -> {ok, id()} | {error, term()}.
%% @doc
%% Persists an event to the event store.
%%
%% @param StreamId The identifier of the event stream.
%% @param Version The version number of the event.
%% @param Payload The event data to be persisted.
%% @return Returns 'ok' if the event is successfully persisted, or an error tuple if
%% the operation fails.
%%
persist_event(StreamId, Version, Payload) ->
    UUID = uuid:get_v4(),
    Id = uuid:uuid_to_string(UUID),
    Timestamp = calendar:universal_time(),
    Record =
        #event_record{id = Id,
                      % by convention
                      type = atom_to_list(element(1, Payload)),
                      stream_id = StreamId,
                      version = Version,
                      tags = [],
                      timestamp = Timestamp,
                      metadata = #{},
                      payload = Payload},
    case mnesia:transaction(fun() -> mnesia:write(?EVENT_TABLE_NAME, Record, write) end) of
        {atomic, ok} ->
            {ok, Id};
        {aborted, Reason} ->
            {error, Reason}
    end.

%%
%% @doc
%% Retrieves and folds events for a given stream ID.
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
%%
-spec retrieve_and_fold_events(stream_id(),
                               [{from, non_neg_integer()} | {to, non_neg_integer()}],
                               fun((event_record(), Acc) -> Acc),
                               Acc) ->
                                  {ok, Acc} | {error, term()}.
retrieve_and_fold_events(StreamId, Options, FoldFun, InitialAcc)
    when is_list(Options), is_function(FoldFun, 2) ->
    From = proplists:get_value(from, Options, 0),
    To = proplists:get_value(to, Options, infinity),

    FunQuery =
        fun() ->
           qlc:e(
               qlc:q([E
                      || E <- mnesia:table(?EVENT_TABLE_NAME),
                         E#event_record.stream_id =:= StreamId,
                         E#event_record.version >= From,
                         To =:= infinity orelse E#event_record.version < To]))
        end,

    case mnesia:transaction(FunQuery) of
        {atomic, Events} ->
            SortedEvents =
                lists:sort(fun(E1, E2) -> E1#event_record.version =< E2#event_record.version end,
                           Events),
            Data = lists:foldl(fun(E, Acc) -> FoldFun(E, Acc) end, InitialAcc, SortedEvents),
            {ok, Data};
        {aborted, Reason} ->
            {error, Reason}
    end.
