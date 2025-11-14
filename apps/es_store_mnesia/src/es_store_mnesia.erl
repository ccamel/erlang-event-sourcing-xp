-module(es_store_mnesia).
-moduledoc """
The Mnesia-based implementation of the event store.
""".

-behaviour(es_event_store_behaviour).
-behaviour(es_snapshot_store_behaviour).

-include_lib("stdlib/include/qlc.hrl").
-include_lib("es_contract/include/es_contract.hrl").

-export([
    start/0,
    stop/0,
    fold/4,
    append/2,
    store/1,
    load_latest/1
]).

-export_type([
    event/0, stream_id/0, sequence/0, timestamp/0, snapshot/0, snapshot_data/0
]).

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

-spec append(StreamId, Events) -> ok when
    StreamId :: stream_id(),
    Events :: [event()].
append(StreamId, Events) ->
    case mnesia:transaction(fun() -> persist_events_in_tx(StreamId, Events) end) of
        {atomic, _Result} ->
            ok;
        {aborted, Reason} ->
            erlang:error(Reason)
    end.

persist_events_in_tx(_, []) ->
    ok;
persist_events_in_tx(StreamId, [Event | Rest]) ->
    Id = es_kernel_store:id(Event),
    Record =
        #event_record{
            key = Id,
            stream_id = es_kernel_store:stream_id(Event),
            sequence = es_kernel_store:sequence(Event),
            event = Event
        },
    case mnesia:read(?EVENT_TABLE_NAME, Id, read) of
        [_] ->
            mnesia:abort(duplicate_event);
        _ ->
            ok = mnesia:write(?EVENT_TABLE_NAME, Record, write),
            persist_events_in_tx(StreamId, Rest)
    end.

-spec fold(StreamId, Fun, Acc0, Range) -> Acc1 when
    StreamId :: stream_id(),
    Fun :: fun((Event :: event(), AccIn) -> AccOut),
    Acc0 :: term(),
    Range :: es_range:range(),
    Acc1 :: term(),
    AccIn :: term(),
    AccOut :: term().
fold(StreamId, FoldFun, InitialAcc, Range) when
    is_function(FoldFun, 2)
->
    From = es_range:lower_bound(Range),
    To = es_range:upper_bound(Range),
    FunQuery =
        fun() ->
            qlc:e(
                qlc:q(
                    [
                        E#event_record.event
                     || E <- mnesia:table(?EVENT_TABLE_NAME),
                        E#event_record.stream_id =:= StreamId,
                        E#event_record.sequence >= From,
                        E#event_record.sequence < To
                    ],
                    []
                )
            )
        end,
    case mnesia:transaction(FunQuery) of
        {atomic, Events} ->
            lists:foldl(FoldFun, InitialAcc, Events);
        {aborted, Reason} ->
            erlang:error(Reason)
    end.

-spec store(Snapshot) -> ok | {warning, Reason} when
    Snapshot :: snapshot(),
    Reason :: term().
store(Snapshot) ->
    try
        Record = #snapshot_record{
            stream_id = es_kernel_store:snapshot_stream_id(Snapshot),
            sequence = es_kernel_store:snapshot_sequence(Snapshot),
            timestamp = es_kernel_store:snapshot_timestamp(Snapshot),
            snapshot = Snapshot
        },
        ok = mnesia:dirty_write(?SNAPSHOT_TABLE_NAME, Record),
        ok
    catch
        Class:Reason ->
            {warning, {Class, Reason}}
    end.

-spec load_latest(StreamId) -> {ok, Snapshot} | {error, not_found} when
    StreamId :: stream_id(),
    Snapshot :: snapshot().
load_latest(StreamId) ->
    Fun = fun() -> mnesia:read(?SNAPSHOT_TABLE_NAME, StreamId, read) end,
    case mnesia:transaction(Fun) of
        {atomic, [#snapshot_record{snapshot = Snapshot}]} ->
            {ok, Snapshot};
        {atomic, []} ->
            {error, not_found};
        {aborted, Reason} ->
            erlang:error(Reason)
    end.
