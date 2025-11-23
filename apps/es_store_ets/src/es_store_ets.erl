-module(es_store_ets).
-moduledoc """
The ETS-based implementation of the event store.
""".

-behaviour(es_contract_event_store).
-behaviour(es_contract_snapshot_store).

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

-define(DEFAULT_EVENT_TABLE_NAME, events).
-define(DEFAULT_SNAPSHOT_TABLE_NAME, snapshots).

-spec start() -> ok.
start() ->
    EventTable = event_table_name(),
    SnapshotTable = snapshot_table_name(),
    case ets:info(EventTable) of
        undefined ->
            _ = ets:new(
                EventTable,
                [ordered_set, named_table, public, {keypos, #event_record.key}]
            ),
            ok;
        _ ->
            ok
    end,
    case ets:info(SnapshotTable) of
        undefined ->
            _ = ets:new(
                SnapshotTable,
                [set, named_table, public, {keypos, #snapshot_record.stream_id}]
            ),
            ok;
        _ ->
            ok
    end.

-spec stop() -> ok.
stop() ->
    ets:delete(event_table_name()),
    ets:delete(snapshot_table_name()),
    ok.

-spec append(StreamId, Events) -> ok when
    StreamId :: stream_id(),
    Events :: [event()].
append(_, Events) ->
    Records = lists:map(fun event_to_record/1, Events),
    case ets:insert_new(event_table_name(), Records) of
        true ->
            ok;
        false ->
            erlang:error(duplicate_event)
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

    Pattern = {event_record, '_', StreamId, '$1', '$2'},
    Guard = [{'>=', '$1', From}, {'<', '$1', To}],
    MatchSpec = [{Pattern, Guard, ['$2']}],
    ResultEvents = ets:select(event_table_name(), MatchSpec),
    lists:foldl(FoldFun, InitialAcc, ResultEvents).

event_to_record(Event) ->
    #event_record{
        key = es_kernel_store:id(Event),
        stream_id = es_kernel_store:stream_id(Event),
        sequence = es_kernel_store:sequence(Event),
        event = Event
    }.

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
        true = ets:insert(snapshot_table_name(), Record),
        ok
    catch
        Class:Reason ->
            {warning, {Class, Reason}}
    end.

-spec load_latest(StreamId) -> {ok, Snapshot} | {error, not_found} when
    StreamId :: stream_id(),
    Snapshot :: snapshot().
load_latest(StreamId) ->
    case ets:lookup(snapshot_table_name(), StreamId) of
        [#snapshot_record{snapshot = Snapshot}] ->
            {ok, Snapshot};
        [] ->
            {error, not_found}
    end.

-spec event_table_name() -> atom().
event_table_name() ->
    application:get_env(es_store_ets, event_table_name, ?DEFAULT_EVENT_TABLE_NAME).

-spec snapshot_table_name() -> atom().
snapshot_table_name() ->
    application:get_env(es_store_ets, snapshot_table_name, ?DEFAULT_SNAPSHOT_TABLE_NAME).
