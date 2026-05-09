-module(bank_account_balance_projection).

-behaviour(es_contract_projection).

-export([init/0, name/0, event_filter/1, handle_event/2]).

init() ->
    #{}.

name() ->
    bank_account_balance_projection.

event_filter(#{aggregate_type := bank_account}) ->
    true;
event_filter(_) ->
    false.

handle_event(
    #{stream_id := {bank_account, AccountId}, type := deposited, payload := #{amount := Amount}},
    State
) ->
    NewState = update_balance(AccountId, Amount, State),
    log_state(AccountId, NewState),
    {ok, NewState};
handle_event(
    #{stream_id := {bank_account, AccountId}, type := withdrawn, payload := #{amount := Amount}},
    State
) ->
    NewState = update_balance(AccountId, -Amount, State),
    log_state(AccountId, NewState),
    {ok, NewState};
handle_event(_, State) ->
    {ok, State}.

update_balance(AccountId, Delta, State) ->
    Balance = maps:get(AccountId, State, 0),
    State#{AccountId => Balance + Delta}.

log_state(AccountId, State) ->
    logger:info("Bank account projection updated: account=~p state=~p", [AccountId, State]).
