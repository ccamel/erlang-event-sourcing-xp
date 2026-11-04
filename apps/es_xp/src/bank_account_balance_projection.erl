-module(bank_account_balance_projection).

-behaviour(es_contract_projection).

-export([init/0, name/0, event_filter/1, handle_event/3]).

init() ->
    undefined.

name() ->
    bank_account_balance_projection.

event_filter(#{aggregate_type := bank_account}) ->
    true;
event_filter(_) ->
    false.

handle_event(
    #{stream_id := {bank_account, AccountId}, type := deposited, payload := #{amount := Amount}},
    Position,
    State
) ->
    ok = es_xp_balance_view:record_change(Position, AccountId, Amount),
    {ok, State};
handle_event(
    #{stream_id := {bank_account, AccountId}, type := withdrawn, payload := #{amount := Amount}},
    Position,
    State
) ->
    ok = es_xp_balance_view:record_change(Position, AccountId, -Amount),
    {ok, State};
handle_event(_, _Position, State) ->
    {ok, State}.
