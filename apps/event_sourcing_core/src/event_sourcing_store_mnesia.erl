-module(event_sourcing_store_mnesia).

-behaviour(event_sourcing_store).

-include_lib("stdlib/include/qlc.hrl").

-export([table_name/1, start/0, stop/0, retrieve_and_fold_events/4, persist_event/3]).

-record(event_record,
        {id, type, stream_id, version, tags = [], timestamp, metadata = #{}, payload}).

%% @doc The name of the table that will store events.
-define(EVENT_TABLE_NAME, events).

%% @doc The name of the tables used for persistence.
-spec table_name(events) -> events.
table_name(events) ->
    ?EVENT_TABLE_NAME.

-spec start() -> {ok, initialized | already_initialized} | {error, term()}.
start() ->
    try mnesia:table_info(?EVENT_TABLE_NAME, all) of
        _ ->
            {ok, already_initialized}
    catch
        exit:{aborted, {no_exists, ?EVENT_TABLE_NAME, all}} ->
            case mnesia:create_table(?EVENT_TABLE_NAME,
                                     [{attributes, record_info(fields, event_record)},
                                      {record_name, event_record},
                                      {type, set},
                                      {index, [type, stream_id, version]}])
            of
                {atomic, ok} ->
                    {ok, initialized};
                {aborted, Reason} ->
                    {error, Reason}
            end
    end.

-spec stop() -> {ok}.
stop() ->
    {ok}.

-spec persist_event(event_sourcing_store:stream_id(),
                    event_sourcing_store:version(),
                    event_sourcing_store:payload()) ->
                       {ok, event_sourcing_store:id()} | {error, term()}.
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

-spec retrieve_and_fold_events(event_sourcing_store:stream_id(),
                               [{from, non_neg_integer()} | {to, non_neg_integer()}],
                               fun((event_sourcing_store:event_record(), Acc) -> Acc),
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
