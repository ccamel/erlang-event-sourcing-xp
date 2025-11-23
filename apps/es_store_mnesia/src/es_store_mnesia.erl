-module(es_store_mnesia).
-moduledoc """
The Mnesia-based implementation of the event store.
""".

-behaviour(es_contract_event_store).
-behaviour(es_contract_snapshot_store).

-include_lib("stdlib/include/qlc.hrl").

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

-type stream_id() :: es_contract_event:stream_id().
-type sequence() :: es_contract_event:sequence().
-type timestamp() :: non_neg_integer().
-type event_id() :: es_contract_event:key().
-type event() :: es_contract_event:t().
-type snapshot() :: es_contract_snapshot:t().
-type snapshot_data() :: es_contract_snapshot:state().

-record(event_record, {
    key :: event_id(), stream_id :: stream_id(), sequence :: sequence(), event :: event()
}).

-record(snapshot_record, {
    stream_id :: stream_id(),
    sequence :: sequence(),
    timestamp :: non_neg_integer(),
    snapshot :: snapshot()
}).

%% Default table names; overridable via application environment.
-define(DEFAULT_EVENT_TABLE_NAME, events).
-define(DEFAULT_SNAPSHOT_TABLE_NAME, snapshots).

-spec start() -> ok.
start() ->
    EventTable = event_table_name(),
    SnapshotTable = snapshot_table_name(),
    try mnesia:table_info(EventTable, all) of
        _ ->
            ok
    catch
        exit:{aborted, {no_exists, EventTable, all}} ->
            case
                mnesia:create_table(
                    EventTable,
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
    try mnesia:table_info(SnapshotTable, all) of
        _ ->
            ok
    catch
        exit:{aborted, {no_exists, SnapshotTable, all}} ->
            case
                mnesia:create_table(
                    SnapshotTable,
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
    case mnesia:read(event_table_name(), Id, read) of
        [_] ->
            mnesia:abort(duplicate_event);
        _ ->
            ok = mnesia:write(event_table_name(), Record, write),
            persist_events_in_tx(StreamId, Rest)
    end.

-spec fold(StreamId, Fun, Acc0, Range) -> Acc1 when
    StreamId :: stream_id(),
    Fun :: fun((Event :: event(), AccIn) -> AccOut),
    Acc0 :: term(),
    Range :: es_contract_range:range(),
    Acc1 :: term(),
    AccIn :: term(),
    AccOut :: term().
fold(StreamId, FoldFun, InitialAcc, Range) when
    is_function(FoldFun, 2)
->
    From = es_contract_range:lower_bound(Range),
    To = es_contract_range:upper_bound(Range),
    FunQuery =
        fun() ->
            qlc:e(
                qlc:q(
                    [
                        E#event_record.event
                     || E <- mnesia:table(event_table_name()),
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
        ok = mnesia:dirty_write(snapshot_table_name(), Record),
        ok
    catch
        Class:Reason ->
            {warning, {Class, Reason}}
    end.

-spec load_latest(StreamId) -> {ok, Snapshot} | {error, not_found} when
    StreamId :: stream_id(),
    Snapshot :: snapshot().
load_latest(StreamId) ->
    Fun = fun() -> mnesia:read(snapshot_table_name(), StreamId, read) end,
    case mnesia:transaction(Fun) of
        {atomic, [#snapshot_record{snapshot = Snapshot}]} ->
            {ok, Snapshot};
        {atomic, []} ->
            {error, not_found};
        {aborted, Reason} ->
            erlang:error(Reason)
    end.

-spec event_table_name() -> atom().
event_table_name() ->
    application:get_env(es_store_mnesia, event_table_name, ?DEFAULT_EVENT_TABLE_NAME).

-spec snapshot_table_name() -> atom().
snapshot_table_name() ->
    application:get_env(es_store_mnesia, snapshot_table_name, ?DEFAULT_SNAPSHOT_TABLE_NAME).
