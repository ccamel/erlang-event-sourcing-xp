-module(es_xp_balance_view_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PROJECTION, bank_account_balance_projection).

view_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun redelivered_change_is_applied_once/0,
        fun checkpoint_tracks_filtered_positions/0
    ]}.

setup() ->
    {ok, Pid} = es_xp_balance_view:start_link(),
    unlink(Pid),
    Pid.

teardown(Pid) ->
    gen_server:stop(Pid).

redelivered_change_is_applied_once() ->
    ?assertEqual({error, not_found}, es_xp_balance_view:load_checkpoint(?PROJECTION)),
    ok = es_xp_balance_view:record_change(0, <<"a">>, 100),
    %% At-least-once: a crash before the checkpoint commit redelivers position 0.
    ok = es_xp_balance_view:record_change(0, <<"a">>, 100),
    ok = es_xp_balance_view:record_change(1, <<"a">>, -30),
    ?assertEqual({ok, 70, 1}, es_xp_balance_view:balance(<<"a">>)),
    ?assertEqual({ok, 0, 1}, es_xp_balance_view:balance(<<"b">>)).

checkpoint_tracks_filtered_positions() ->
    ok = es_xp_balance_view:record_change(0, <<"a">>, 100),
    ok = es_xp_balance_view:store_checkpoint(?PROJECTION, 3),
    ?assertEqual({ok, 3}, es_xp_balance_view:load_checkpoint(?PROJECTION)),
    ok = es_xp_balance_view:record_change(2, <<"a">>, 100),
    ?assertEqual({ok, 100, 3}, es_xp_balance_view:balance(<<"a">>)).
