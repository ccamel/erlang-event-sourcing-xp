-module(event_sourcing_store_mnesia).

-behaviour(event_sourcing_store).

-include_lib("stdlib/include/qlc.hrl").

-export([table_name/1, start/0, stop/0, retrieve_and_fold_events/4, persist_event/1]).

-record(event_record,
        {key :: event_sourcing_store:id(),
         stream_id :: event_sourcing_store:stream_id(),
         sequence :: event_sourcing_store:sequence(),
         event :: event_sourcing_store:event()}).

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
                                      {type, ordered_set},
                                      {index, [stream_id, sequence]}])
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

-spec persist_event(Event :: event_sourcing_store:event()) -> ok | {error, term()}.
persist_event(Event) ->
    Record =
        #event_record{key = event_sourcing_store:id(Event),
                      stream_id = event_sourcing_store:stream_id(Event),
                      sequence = event_sourcing_store:sequence(Event),
                      event = Event},
    case mnesia:transaction(fun() -> mnesia:write(?EVENT_TABLE_NAME, Record, write) end) of
        {atomic, ok} ->
            ok;
        {aborted, Reason} ->
            {error, Reason}
    end.

-spec retrieve_and_fold_events(event_sourcing_store:stream_id(),
                               event_sourcing_store:fold_events_opts(),
                               event_sourcing_store:fold_events_fun(),
                               event_sourcing_store:acc()) ->
                                  {ok, event_sourcing_store:acc()} | {error, term()}.
retrieve_and_fold_events(StreamId, Options, FoldFun, InitialAcc)
    when is_list(Options), is_function(FoldFun, 2) ->
    From = proplists:get_value(from, Options, 0),
    To = proplists:get_value(to, Options, infinity),
    Limit = proplists:get_value(limit, Options, infinity),
    FunQuery =
        fun() ->
           Q = qlc:q([E#event_record.event
                      || E <- mnesia:table(?EVENT_TABLE_NAME),
                         E#event_record.stream_id =:= StreamId,
                         E#event_record.sequence >= From,
                         E#event_record.sequence < To],
                     []),
           case Limit of
               infinity ->
                   qlc:e(Q);
               N when is_integer(N), N > 0 ->
                   Cursor = qlc:cursor(Q),
                   Events = qlc:next_answers(Cursor, N),
                   qlc:delete_cursor(Cursor),
                   Events;
               _ ->
                   qlc:e(Q)
           end
        end,
    case mnesia:transaction(FunQuery) of
        {atomic, Events} ->
            {ok, lists:foldl(FoldFun, InitialAcc, Events)};
        {aborted, Reason} ->
            {error, Reason}
    end.
