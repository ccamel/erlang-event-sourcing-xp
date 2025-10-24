-module(event_sourcing_core_store_ets).
-moduledoc """
The ETS-based implementation of the event store.
""".

-behaviour(event_sourcing_core_store).

-include_lib("event_sourcing_core.hrl").

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

%% The name of the ETS table that will store events.
-define(EVENT_TABLE_NAME, events).

%% The name of the ETS table that will store snapshots.
-define(SNAPSHOT_TABLE_NAME, snapshots).

-spec start() -> ok.
start() ->
    case ets:info(?EVENT_TABLE_NAME) of
        undefined ->
            _ = ets:new(
                ?EVENT_TABLE_NAME,
                [ordered_set, named_table, public, {keypos, #event_record.key}]
            ),
            ok;
        _ ->
            ok
    end,
    case ets:info(?SNAPSHOT_TABLE_NAME) of
        undefined ->
            _ = ets:new(
                ?SNAPSHOT_TABLE_NAME,
                [set, named_table, public, {keypos, #snapshot_record.stream_id}]
            ),
            ok;
        _ ->
            ok
    end.

-spec stop() -> ok.
stop() ->
    ets:delete(?EVENT_TABLE_NAME),
    ets:delete(?SNAPSHOT_TABLE_NAME),
    ok.

-spec persist_events(StreamId, Events) -> ok when
    StreamId :: stream_id(),
    Events :: [event()].
persist_events(_, Events) ->
    Records = lists:map(fun event_to_record/1, Events),
    case ets:insert_new(?EVENT_TABLE_NAME, Records) of
        true ->
            ok;
        false ->
            erlang:error(duplicate_event)
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

    Pattern = {event_record, '_', StreamId, '$1', '$2'},
    Guard = [{'>=', '$1', From}, {'<', '$1', To}],
    MatchSpec = [{Pattern, Guard, ['$2']}],
    ResultEvents =
        case Limit of
            infinity ->
                ets:select(?EVENT_TABLE_NAME, MatchSpec);
            _ ->
                Events = ets:select(?EVENT_TABLE_NAME, MatchSpec, Limit),
                case Events of
                    {EventList, _Continuation} ->
                        EventList;
                    '$end_of_table' ->
                        []
                end
        end,
    lists:foldl(FoldFun, InitialAcc, ResultEvents).

event_to_record(Event) ->
    #event_record{
        key = event_sourcing_core_store:id(Event),
        stream_id = event_sourcing_core_store:stream_id(Event),
        sequence = event_sourcing_core_store:sequence(Event),
        event = Event
    }.

-spec save_snapshot(Snapshot) -> ok when
    Snapshot :: snapshot().
save_snapshot(Snapshot) ->
    Record = #snapshot_record{
        stream_id = event_sourcing_core_store:snapshot_stream_id(Snapshot),
        sequence = event_sourcing_core_store:snapshot_sequence(Snapshot),
        timestamp = event_sourcing_core_store:snapshot_timestamp(Snapshot),
        snapshot = Snapshot
    },
    true = ets:insert(?SNAPSHOT_TABLE_NAME, Record),
    ok.

-spec retrieve_latest_snapshot(StreamId) -> {ok, Snapshot} | {error, not_found} when
    StreamId :: stream_id(),
    Snapshot :: snapshot().
retrieve_latest_snapshot(StreamId) ->
    case ets:lookup(?SNAPSHOT_TABLE_NAME, StreamId) of
        [#snapshot_record{snapshot = Snapshot}] ->
            {ok, Snapshot};
        [] ->
            {error, not_found}
    end.
