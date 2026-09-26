-module(es_xp_account_query).
-moduledoc """
Read-side query for bank-account balances.
""".

-export([balance/1]).

-spec balance(binary()) -> {ok, integer()} | {error, term()}.
balance(AccountId) when is_binary(AccountId) ->
    StoreContext = es_kernel_app:get_store_context(),
    es_kernel_store:fold(
        StoreContext,
        {bank_account, AccountId},
        fun apply_event/3,
        0,
        es_contract_range:new(0, infinity)
    ).

apply_event(#{type := deposited, payload := #{amount := Amount}}, _Sequence, Balance) ->
    Balance + Amount;
apply_event(#{type := withdrawn, payload := #{amount := Amount}}, _Sequence, Balance) ->
    Balance - Amount;
apply_event(_Event, _Sequence, Balance) ->
    Balance.
