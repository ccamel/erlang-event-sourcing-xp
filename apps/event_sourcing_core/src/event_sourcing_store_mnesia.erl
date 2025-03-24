-module(event_sourcing_store_mnesia).

-behaviour(event_sourcing_store).

-include_lib("stdlib/include/qlc.hrl").

-export([start/0, stop/0, retrieve_and_fold_events/4, persist_events/2]).

-record(event_record,
        {key :: event_sourcing_store:id(),
         stream_id :: event_sourcing_store:stream_id(),
         sequence :: event_sourcing_store:sequence(),
         event :: event_sourcing_store:event()}).

%% @doc The name of the table that will store events.
-define(EVENT_TABLE_NAME, events).

-spec start() -> ok.
start() ->
    try mnesia:table_info(?EVENT_TABLE_NAME, all) of
        _ ->
            ok
    catch
        exit:{aborted, {no_exists, ?EVENT_TABLE_NAME, all}} ->
            case mnesia:create_table(?EVENT_TABLE_NAME,
                                     [{attributes, record_info(fields, event_record)},
                                      {record_name, event_record},
                                      {type, ordered_set},
                                      {index, [stream_id, sequence]}])
            of
                {atomic, ok} ->
                    ok;
                {aborted, Reason} ->
                    erlang:error(Reason)
            end
    end.

-spec stop() -> ok.
stop() ->
    ok.

-spec persist_events(StreamId, Events) -> ok
    when StreamId :: event_sourcing_store:stream_id(),
         Events :: [event_sourcing_store:event()].
persist_events(StreamId, Events) ->
    case mnesia:transaction(fun() -> persist_events_in_tx(StreamId, Events) end) of
        {atomic, _Result} ->
            ok;
        {aborted, Reason} ->
            erlang:error(Reason)
    end.

persist_events_in_tx(_, []) ->
    ok;
persist_events_in_tx(StreamId, [Event | Rest]) ->
    Id = event_sourcing_store:id(Event),
    Record =
        #event_record{key = Id,
                      stream_id = event_sourcing_store:stream_id(Event),
                      sequence = event_sourcing_store:sequence(Event),
                      event = Event},
    case mnesia:read(?EVENT_TABLE_NAME, Id, read) of
        [_] ->
            mnesia:abort(duplicate_event);
        _ ->
            ok = mnesia:write(?EVENT_TABLE_NAME, Record, write),
            persist_events_in_tx(StreamId, Rest)
    end.

-spec retrieve_and_fold_events(StreamId, Options, Fun, Acc0) -> Acc1
    when StreamId :: event_sourcing_store:stream_id(),
         Options :: event_sourcing_store:fold_events_opts(),
         Fun :: fun((Event :: event_sourcing_store:event(), AccIn) -> AccOut),
         Acc0 :: term(),
         Acc1 :: term(),
         AccIn :: term(),
         AccOut :: term().
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
            lists:foldl(FoldFun, InitialAcc, Events);
        {aborted, Reason} ->
            erlang:error(Reason)
    end.
