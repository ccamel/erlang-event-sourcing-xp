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
    fold_all/3,
    append/3,
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
    key :: event_id(),
    stream_id :: stream_id(),
    sequence :: sequence(),
    position :: es_contract_event_store:position(),
    event :: event()
}).

-record(snapshot_record, {
    stream_id :: stream_id(),
    sequence :: sequence(),
    timestamp :: non_neg_integer(),
    snapshot :: snapshot()
}).

-define(DEFAULT_EVENT_TABLE_NAME, events).
-define(DEFAULT_SNAPSHOT_TABLE_NAME, snapshots).
-define(DEFAULT_POSITION_COUNTER_TABLE_NAME, position_counter).

-spec start() -> ok.
start() ->
    EventTable = event_table_name(),
    SnapshotTable = snapshot_table_name(),
    PositionCounterTable = position_counter_table_name(),
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
    end,
    case ets:info(PositionCounterTable) of
        undefined ->
            _ = ets:new(
                PositionCounterTable,
                [set, named_table, public]
            ),
            %% Initialize global position counter to 0
            ets:insert(PositionCounterTable, {global_position, 0}),
            ok;
        _ ->
            ok
    end.

-spec stop() -> ok.
stop() ->
    delete_table(event_table_name()),
    delete_table(snapshot_table_name()),
    delete_table(position_counter_table_name()),
    ok.

-spec append(StreamId, ExpectedSequence, Events) ->
    {ok, NewSequence} | {error, Reason}
when
    StreamId :: stream_id(),
    ExpectedSequence :: sequence(),
    Events :: [event()],
    NewSequence :: sequence(),
    Reason :: term().
append(StreamId, ExpectedSequence, Events) ->
    case es_contract_event_store:validate_append(StreamId, ExpectedSequence, Events) of
        ok ->
            %% ponytail: global append lock; partition only with a commit-ordered log.
            global:trans(
                {{?MODULE, append}, self()},
                fun() -> append_locked(StreamId, ExpectedSequence, Events) end,
                [node()],
                infinity
            );
        {error, _} = Error ->
            Error
    end.

append_locked(StreamId, ExpectedSequence, Events) ->
    EventTable = event_table_name(),
    ActualSequence = stream_sequence(EventTable, StreamId),
    case ExpectedSequence =:= ActualSequence of
        false ->
            {error, {wrong_expected_sequence, ExpectedSequence, ActualSequence}};
        true ->
            append_at_sequence(EventTable, ExpectedSequence, Events)
    end.

append_at_sequence(_EventTable, ExpectedSequence, []) ->
    {ok, ExpectedSequence};
append_at_sequence(EventTable, ExpectedSequence, Events) ->
    NumEvents = length(Events),
    PositionCounterTable = position_counter_table_name(),
    NewPosition = ets:update_counter(PositionCounterTable, global_position, NumEvents),
    Records = records_with_positions(Events, NewPosition - NumEvents),
    case ets:insert_new(EventTable, Records) of
        true ->
            {ok, ExpectedSequence + NumEvents};
        false ->
            _ = ets:update_counter(PositionCounterTable, global_position, -NumEvents),
            {error, duplicate_event}
    end.

records_with_positions([], _Position) ->
    [];
records_with_positions([Event | Rest], Position) ->
    [event_to_record(Event, Position) | records_with_positions(Rest, Position + 1)].

stream_sequence(EventTable, StreamId) ->
    ets:foldl(
        fun
            (#event_record{stream_id = EventStream, sequence = Sequence}, Actual) when
                EventStream =:= StreamId, Sequence > Actual
            ->
                Sequence;
            (_, Actual) ->
                Actual
        end,
        0,
        EventTable
    ).

-spec fold(StreamId, Fun, Acc0, Range) -> {ok, Acc1} | {error, Reason} when
    StreamId :: stream_id(),
    Fun :: fun(
        (
            Event :: event(),
            Sequence :: sequence(),
            AccIn
        ) -> AccOut
    ),
    Acc0 :: term(),
    Range :: es_contract_range:range(),
    Acc1 :: term(),
    AccIn :: term(),
    AccOut :: term(),
    Reason :: term().
fold(StreamId, FoldFun, InitialAcc, Range) when
    is_function(FoldFun, 3)
->
    try
        From = es_contract_range:lower_bound(Range),
        To = es_contract_range:upper_bound(Range),

        Pattern = {event_record, '_', StreamId, '$1', '_', '$2'},
        Guard = [{'>=', '$1', From}, {'<', '$1', To}],
        MatchSpec = [{Pattern, Guard, [{{'$1', '$2'}}]}],
        ResultPairs = ets:select(event_table_name(), MatchSpec),
        SortedPairs = lists:sort(ResultPairs),
        Result = lists:foldl(
            fun({Seq, Event}, Acc) -> FoldFun(Event, Seq, Acc) end,
            InitialAcc,
            SortedPairs
        ),
        {ok, Result}
    catch
        Class:Reason:Stacktrace ->
            {error, {Class, Reason, Stacktrace}}
    end.

event_to_record(Event, Position) ->
    #event_record{
        key = es_contract_event:key(Event),
        stream_id = maps:get(stream_id, Event),
        sequence = maps:get(sequence, Event),
        position = Position,
        event = Event
    }.

delete_table(Table) ->
    case ets:info(Table) of
        undefined ->
            ok;
        _ ->
            ets:delete(Table)
    end.

-spec store(Snapshot) -> ok | {warning, Reason} when
    Snapshot :: snapshot(),
    Reason :: term().
store(
    #{stream_id := StreamId, sequence := Sequence, metadata := #{timestamp := Timestamp}} = Snapshot
) ->
    try
        Record = #snapshot_record{
            stream_id = StreamId,
            sequence = Sequence,
            timestamp = Timestamp,
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

-spec fold_all(Fun, Acc0, Range) -> {ok, Acc1} | {error, Reason} when
    Fun :: fun((Event :: event(), Position :: es_contract_event_store:position(), AccIn) -> AccOut),
    Acc0 :: term(),
    Range :: es_contract_range:range(),
    Acc1 :: term(),
    AccIn :: term(),
    AccOut :: term(),
    Reason :: term().
fold_all(FoldFun, InitialAcc, Range) when is_function(FoldFun, 3) ->
    try
        From = es_contract_range:lower_bound(Range),
        To = es_contract_range:upper_bound(Range),
        Pattern = {event_record, '_', '_', '_', '$1', '$2'},
        Guard = [{'>=', '$1', From}, {'<', '$1', To}],
        MatchSpec = [{Pattern, Guard, [{{'$1', '$2'}}]}],
        Results = ets:select(event_table_name(), MatchSpec),
        Sorted = lists:sort(Results),
        Result = lists:foldl(
            fun({Position, Event}, Acc) ->
                FoldFun(Event, Position, Acc)
            end,
            InitialAcc,
            Sorted
        ),
        {ok, Result}
    catch
        Class:Reason:Stacktrace ->
            {error, {Class, Reason, Stacktrace}}
    end.

-spec event_table_name() -> atom().
event_table_name() ->
    application:get_env(es_store_ets, event_table_name, ?DEFAULT_EVENT_TABLE_NAME).

-spec snapshot_table_name() -> atom().
snapshot_table_name() ->
    application:get_env(es_store_ets, snapshot_table_name, ?DEFAULT_SNAPSHOT_TABLE_NAME).

-spec position_counter_table_name() -> atom().
position_counter_table_name() ->
    application:get_env(
        es_store_ets, position_counter_table_name, ?DEFAULT_POSITION_COUNTER_TABLE_NAME
    ).
