-module(event_sourcing_core_store_snapshot_stub).

-include_lib("event_sourcing_core/include/event_sourcing_core.hrl").

-export([start/0, stop/0, save_snapshot/1, retrieve_latest_snapshot/1]).

-define(TABLE, ?MODULE).

-spec start() -> ok.
start() ->
    case ets:info(?TABLE) of
        undefined ->
            _ = ets:new(?TABLE, [set, named_table, public]),
            ok;
        _ ->
            ok
    end.

-spec stop() -> ok.
stop() ->
    case ets:info(?TABLE) of
        undefined ->
            ok;
        _ ->
            ets:delete(?TABLE),
            ok
    end.

-spec save_snapshot(snapshot()) -> ok.
save_snapshot(Snapshot) ->
    StreamId = event_sourcing_core_store:snapshot_stream_id(Snapshot),
    ets:insert(?TABLE, {StreamId, Snapshot}),
    ok.

-spec retrieve_latest_snapshot(stream_id()) -> {ok, snapshot()} | {error, not_found}.
retrieve_latest_snapshot(StreamId) ->
    case ets:lookup(?TABLE, StreamId) of
        [{_, Snapshot}] ->
            {ok, Snapshot};
        [] ->
            {error, not_found}
    end.
