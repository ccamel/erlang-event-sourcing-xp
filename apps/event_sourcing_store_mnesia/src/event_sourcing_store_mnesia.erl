-module(event_sourcing_store_mnesia).
-moduledoc """
The Mnesia-based implementation of the event store.
""".

-behaviour(event_sourcing_core_event_store).
-behaviour(event_sourcing_core_snapshot_store).

-include_lib("stdlib/include/qlc.hrl").
-include_lib("event_sourcing_core/include/event_sourcing_core.hrl").

-export([
    start/0,
    stop/0,
    retrieve_and_fold_events/4,
    persist_events/2,
    save_snapshot/1,
    retrieve_latest_snapshot/1
]).

-export_type([event/0, stream_id/0, sequence/0, timestamp/0, snapshot/0, snapshot_data/0]).

-record(event_record, {
    key :: event_id(), stream_id :: stream_id(), sequence :: sequence(), event :: event()
}).

-record(snapshot_record, {
    stream_id :: stream_id(),
    sequence :: sequence(),
    timestamp :: timestamp(),
    snapshot :: snapshot()
}).

%% The name of the table that will store events.
-define(EVENT_TABLE_NAME, events).

%% The name of the table that will store snapshots.
-define(SNAPSHOT_TABLE_NAME, snapshots).

-spec start() -> ok.
start() ->
    try mnesia:table_info(?EVENT_TABLE_NAME, all) of
        _ ->
            ok
    catch
        exit:{aborted, {no_exists, ?EVENT_TABLE_NAME, all}} ->
            case
                mnesia:create_table(
                    ?EVENT_TABLE_NAME,
                    [
                        {attributes, record_info(fields, event_record)},
                        {record_name, event_record},
                        {type, ordered_set},
                        {index, [stream_id, sequence]}
                    ]
                )
            of
                {atomic, ok} ->
                    ok;
                {aborted, Reason} ->
                    erlang:error(Reason)
            end
    end,
    try mnesia:table_info(?SNAPSHOT_TABLE_NAME, all) of
        _ ->
            ok
    catch
        exit:{aborted, {no_exists, ?SNAPSHOT_TABLE_NAME, all}} ->
            case
                mnesia:create_table(
                    ?SNAPSHOT_TABLE_NAME,
                    [
                        {attributes, record_info(fields, snapshot_record)},
                        {record_name, snapshot_record},
                        {type, set}
                    ]
                )
            of
                {atomic, ok} ->
                    ok;
                {aborted, SnapshotReason} ->
                    erlang:error(SnapshotReason)
            end
    end.

-spec stop() -> ok.
stop() ->
    ok.

-spec persist_events(StreamId, Events) -> ok when
    StreamId :: stream_id(),
    Events :: [event()].
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
    Id = event_sourcing_core_store:id(Event),
    Record =
        #event_record{
            key = Id,
            stream_id = event_sourcing_core_store:stream_id(Event),
            sequence = event_sourcing_core_store:sequence(Event),
            event = Event
        },
    case mnesia:read(?EVENT_TABLE_NAME, Id, read) of
        [_] ->
            mnesia:abort(duplicate_event);
        _ ->
            ok = mnesia:write(?EVENT_TABLE_NAME, Record, write),
            persist_events_in_tx(StreamId, Rest)
    end.

-spec retrieve_and_fold_events(StreamId, Options, Fun, Acc0) -> Acc1 when
    StreamId :: stream_id(),
    Options :: event_sourcing_core_store:fold_events_opts(),
    Fun :: fun((Event :: event(), AccIn) -> AccOut),
    Acc0 :: term(),
    Acc1 :: term(),
    AccIn :: term(),
    AccOut :: term().
retrieve_and_fold_events(StreamId, Options, FoldFun, InitialAcc) when
    is_map(Options), is_function(FoldFun, 2)
->
    From = maps:get(from, Options, 0),
    To = maps:get(to, Options, infinity),
    Limit = maps:get(limit, Options, infinity),
    FunQuery =
        fun() ->
            Q = qlc:q(
                [
                    E#event_record.event
                 || E <- mnesia:table(?EVENT_TABLE_NAME),
                    E#event_record.stream_id =:= StreamId,
                    E#event_record.sequence >= From,
                    E#event_record.sequence < To
                ],
                []
            ),
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

-spec save_snapshot(Snapshot) -> ok | {warning, Reason} when
    Snapshot :: snapshot(),
    Reason :: term().
save_snapshot(Snapshot) ->
    try
        Record = #snapshot_record{
            stream_id = event_sourcing_core_store:snapshot_stream_id(Snapshot),
            sequence = event_sourcing_core_store:snapshot_sequence(Snapshot),
            timestamp = event_sourcing_core_store:snapshot_timestamp(Snapshot),
            snapshot = Snapshot
        },
        ok = mnesia:dirty_write(?SNAPSHOT_TABLE_NAME, Record),
        ok
    catch
        Class:Reason ->
            {warning, {Class, Reason}}
    end.

-spec retrieve_latest_snapshot(StreamId) -> {ok, Snapshot} | {error, not_found} when
    StreamId :: stream_id(),
    Snapshot :: snapshot().
retrieve_latest_snapshot(StreamId) ->
    Fun = fun() -> mnesia:read(?SNAPSHOT_TABLE_NAME, StreamId, read) end,
    case mnesia:transaction(Fun) of
        {atomic, [#snapshot_record{snapshot = Snapshot}]} ->
            {ok, Snapshot};
        {atomic, []} ->
            {error, not_found};
        {aborted, Reason} ->
            erlang:error(Reason)
    end.
