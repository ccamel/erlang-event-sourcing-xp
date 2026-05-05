-module(es_projection_checkpoint_ets).

-moduledoc """
ETS-backed projection checkpoint store.
""".

-behaviour(es_contract_projection_checkpoint_store).

-export([
    start/0,
    stop/0,
    load_checkpoint/1,
    store_checkpoint/2
]).

-define(DEFAULT_TABLE_NAME, projection_checkpoints).

-spec start() -> ok.
start() ->
    Table = table_name(),
    case ets:info(Table) of
        undefined ->
            _ = ets:new(Table, [set, named_table, public]),
            ok;
        _ ->
            ok
    end.

-spec stop() -> ok.
stop() ->
    case ets:info(table_name()) of
        undefined ->
            ok;
        _ ->
            ets:delete(table_name()),
            ok
    end.

-spec load_checkpoint(ProjectionName) -> {ok, Position} | {error, not_found} when
    ProjectionName :: atom(),
    Position :: es_contract_event_store:position().
load_checkpoint(ProjectionName) ->
    case ets:lookup(table_name(), ProjectionName) of
        [{ProjectionName, Position}] ->
            {ok, Position};
        [] ->
            {error, not_found}
    end.

-spec store_checkpoint(ProjectionName, Position) -> ok when
    ProjectionName :: atom(),
    Position :: es_contract_event_store:position().
store_checkpoint(ProjectionName, Position) ->
    true = ets:insert(table_name(), {ProjectionName, Position}),
    ok.

-spec table_name() -> atom().
table_name() ->
    application:get_env(es_kernel, projection_checkpoint_table_name, ?DEFAULT_TABLE_NAME).
