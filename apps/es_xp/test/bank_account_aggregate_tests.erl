-module(bank_account_aggregate_tests).

-include_lib("eunit/include/eunit.hrl").

handle_command_test_() ->
    Cases = [
        %% deposits
        {valid_deposit, #{type => deposit, payload => #{amount => 100}}, #{balance => 0},
            {ok, [#{type => deposited, amount => 100}]}},

        {zero_deposit_is_invalid, #{type => deposit, payload => #{amount => 0}}, #{balance => 0},
            {error, invalid_command}},

        {negative_deposit_is_invalid, #{type => deposit, payload => #{amount => -10}},
            #{balance => 0}, {error, invalid_command}},

        %% withdraws
        {valid_withdraw, #{type => withdraw, payload => #{amount => 50}}, #{balance => 100},
            {ok, [#{type => withdrawn, amount => 50}]}},

        {withdraw_insufficient_funds, #{type => withdraw, payload => #{amount => 200}},
            #{balance => 100}, {error, insufficient_funds}},

        {withdraw_zero_is_invalid, #{type => withdraw, payload => #{amount => 0}},
            #{balance => 100}, {error, invalid_command}},

        {withdraw_negative_is_invalid, #{type => withdraw, payload => #{amount => -10}},
            #{balance => 100}, {error, invalid_command}},

        %% unknown command
        {unknown_command_is_invalid, #{type => foo, payload => #{}}, #{balance => 42},
            {error, invalid_command}}
    ],
    [
        {atom_to_list(Name), fun() ->
            ?assertEqual(
                Expected,
                bank_account_aggregate:handle_command(Command, State)
            )
        end}
     || {Name, Command, State, Expected} <- Cases
    ].
