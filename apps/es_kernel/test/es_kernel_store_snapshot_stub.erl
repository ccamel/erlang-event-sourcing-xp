-module(es_kernel_store_snapshot_stub).

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

-spec store(es_contract_snapshot:t()) -> ok.
store(Snapshot) ->
    StreamId = es_kernel_store:snapshot_stream_id(Snapshot),
    ets:insert(?TABLE, {StreamId, Snapshot}),
    ok.

-spec load_latest(es_contract_event:stream_id()) ->
    {ok, es_contract_snapshot:t()} | {error, not_found}.
load_latest(StreamId) ->
    case ets:lookup(?TABLE, StreamId) of
        [{_, Snapshot}] ->
            {ok, Snapshot};
        [] ->
            {error, not_found}
    end.
