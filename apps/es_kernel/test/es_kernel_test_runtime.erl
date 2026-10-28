-module(es_kernel_test_runtime).

-behaviour(es_contract_domain).

-export([init/1, handle_command/3, apply_event/3, event_type/2]).

init(#{initial := Initial}) ->
    #{balance => Initial}.

handle_command(#{step := Step}, #{type := credit, payload := Units}, _) ->
    {ok, [{credit, Units * Step}]};
handle_command(_, #{type := withdraw, payload := Amount}, #{balance := Balance}) when
    Amount > Balance
->
    {error, insufficient_balance};
handle_command(_, #{type := withdraw, payload := Amount}, _) ->
    {ok, [{debit, Amount}]};
handle_command(_, #{type := idle}, _) ->
    {ok, []}.

apply_event(#{initial := _}, {credit, Amount}, #{balance := Balance}) ->
    #{balance => Balance + Amount};
apply_event(#{initial := _}, {debit, Amount}, #{balance := Balance}) ->
    #{balance => Balance - Amount}.

event_type(#{event_type := Type}, {_, _}) ->
    Type.
