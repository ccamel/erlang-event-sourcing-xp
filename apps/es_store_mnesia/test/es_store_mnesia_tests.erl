-module(es_store_mnesia_tests).

-include_lib("eunit/include/eunit.hrl").

-define(EVENT_TABLE, es_store_mnesia_cache_test_events).
-define(SNAPSHOT_TABLE, es_store_mnesia_cache_test_snapshots).
-define(POSITION_COUNTER_TABLE, es_store_mnesia_cache_test_position_counter).

-define(EVENT_TABLE_NAME_KEY, {es_store_mnesia, event_table_name}).
-define(SNAPSHOT_TABLE_NAME_KEY, {es_store_mnesia, snapshot_table_name}).
-define(POSITION_COUNTER_TABLE_NAME_KEY, {es_store_mnesia, position_counter_table_name}).

table_name_cache_test_() ->
    {foreach, fun setup/0, fun teardown/1, [fun table_name_cache/0]}.

setup() ->
    mnesia:start(),
    application:set_env(es_store_mnesia, event_table_name, ?EVENT_TABLE),
    application:set_env(es_store_mnesia, snapshot_table_name, ?SNAPSHOT_TABLE),
    application:set_env(
        es_store_mnesia, position_counter_table_name, ?POSITION_COUNTER_TABLE
    ),
    ok = es_store_mnesia:start().

teardown(_) ->
    ok = es_store_mnesia:stop(),
    application:unset_env(es_store_mnesia, event_table_name),
    application:unset_env(es_store_mnesia, snapshot_table_name),
    application:unset_env(es_store_mnesia, position_counter_table_name),
    {atomic, ok} = mnesia:delete_table(?EVENT_TABLE),
    {atomic, ok} = mnesia:delete_table(?SNAPSHOT_TABLE),
    {atomic, ok} = mnesia:delete_table(?POSITION_COUNTER_TABLE),
    ok.

table_name_cache() ->
    application:set_env(es_store_mnesia, event_table_name, ignored_event_table),
    application:set_env(es_store_mnesia, snapshot_table_name, ignored_snapshot_table),
    application:set_env(
        es_store_mnesia, position_counter_table_name, ignored_position_counter_table
    ),
    ?assertEqual(?EVENT_TABLE, persistent_term:get(?EVENT_TABLE_NAME_KEY)),
    ?assertEqual(?SNAPSHOT_TABLE, persistent_term:get(?SNAPSHOT_TABLE_NAME_KEY)),
    ?assertEqual(
        ?POSITION_COUNTER_TABLE,
        persistent_term:get(?POSITION_COUNTER_TABLE_NAME_KEY)
    ).
