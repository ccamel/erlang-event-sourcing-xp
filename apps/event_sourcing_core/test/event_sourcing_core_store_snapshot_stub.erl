-module(event_sourcing_core_store_snapshot_stub).

-include_lib("event_sourcing_contract/include/event_sourcing.hrl").

-export([start/0, stop/0, store/1, load_latest/1]).

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

-spec store(snapshot()) -> ok.
store(Snapshot) ->
    StreamId = event_sourcing_core_store:snapshot_stream_id(Snapshot),
    ets:insert(?TABLE, {StreamId, Snapshot}),
    ok.

-spec load_latest(stream_id()) -> {ok, snapshot()} | {error, not_found}.
load_latest(StreamId) ->
    case ets:lookup(?TABLE, StreamId) of
        [{_, Snapshot}] ->
            {ok, Snapshot};
        [] ->
            {error, not_found}
    end.
