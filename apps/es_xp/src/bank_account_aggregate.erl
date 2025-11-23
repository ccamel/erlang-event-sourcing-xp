-module(bank_account_aggregate).

-behaviour(es_contract_aggregate).

%% Callbacks implementation

-export([init/0, event_type/1, handle_command/2, apply_event/2]).

init() ->
    #{balance => 0}.

event_type(#{type := Type}) ->
    Type.

handle_command(#{type := deposit, payload := #{amount := Amount}}, _) when Amount > 0 ->
    {ok, [#{type => deposited, amount => Amount}]};
handle_command(#{type := withdraw, payload := #{amount := Amount}}, #{balance := Balance}) when
    Amount > 0,
    Amount =< Balance
->
    {ok, [#{type => withdrawn, amount => Amount}]};
handle_command(#{type := withdraw, payload := #{amount := Amount}}, _) when Amount > 0 ->
    {error, insufficient_funds};
handle_command(_, _) ->
    {error, invalid_command}.

apply_event(#{type := deposited, amount := Amount}, #{balance := Bal}) ->
    #{balance => Bal + Amount};
apply_event(#{type := withdrawn, amount := Amount}, #{balance := Bal}) ->
    #{balance => Bal - Amount}.
