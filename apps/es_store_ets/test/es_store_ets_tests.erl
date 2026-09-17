-module(es_store_ets_tests).

-include_lib("eunit/include/eunit.hrl").

-define(EVENT_TABLE, es_store_ets_test_events).
-define(SNAPSHOT_TABLE, es_store_ets_test_snapshots).
-define(POSITION_COUNTER_TABLE, es_store_ets_test_position_counter).

stop_is_idempotent_test_() ->
    {foreach, fun setup/0, fun teardown/1, [fun stop_is_idempotent/0]}.

setup() ->
    application:set_env(es_store_ets, event_table_name, ?EVENT_TABLE),
    application:set_env(es_store_ets, snapshot_table_name, ?SNAPSHOT_TABLE),
    application:set_env(es_store_ets, position_counter_table_name, ?POSITION_COUNTER_TABLE),
    ok = es_store_ets:stop().

teardown(_) ->
    ok = es_store_ets:stop(),
    application:unset_env(es_store_ets, event_table_name),
    application:unset_env(es_store_ets, snapshot_table_name),
    application:unset_env(es_store_ets, position_counter_table_name).

stop_is_idempotent() ->
    ok = es_store_ets:start(),
    ok = es_store_ets:stop(),
    ?assertEqual(undefined, ets:info(?EVENT_TABLE)),
    ?assertEqual(undefined, ets:info(?SNAPSHOT_TABLE)),
    ?assertEqual(undefined, ets:info(?POSITION_COUNTER_TABLE)),
    ?assertEqual(ok, es_store_ets:stop()).
