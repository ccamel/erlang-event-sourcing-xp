-module(event_sourcing_interval_tests).

-include_lib("eunit/include/eunit.hrl").

%%% Test suite

suite_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        {"new_interval_creation", fun new_interval_creation/0},
        {"new_interval_validation", fun new_interval_validation/0},
        {"is_empty_check", fun is_empty_check/0},
        {"advance_interval", fun advance_interval/0},
        {"lower_bound_access", fun lower_bound_access/0},
        {"upper_bound_access", fun upper_bound_access/0},
        {"interval_properties", fun interval_properties/0},
        {"edge_cases", fun edge_cases/0}
    ]}.

setup() ->
    ok.

teardown(_) ->
    ok.

%%% Test cases

new_interval_creation() ->
    % Test basic interval creation [0, 10)
    Interval1 = event_sourcing_interval:new(0, 10),
    ?assertEqual({0, 10}, Interval1),

    % Test unbounded interval [5, +∞)
    Interval2 = event_sourcing_interval:new(5, infinity),
    ?assertEqual({5, infinity}, Interval2),

    % Test non-empty single-element interval [7, 8)
    Interval3 = event_sourcing_interval:new(7, 8),
    ?assertEqual({7, 8}, Interval3).

new_interval_validation() ->
    % Test valid cases
    ?assertEqual({1, 5}, event_sourcing_interval:new(1, 5)),
    ?assertEqual({10, infinity}, event_sourcing_interval:new(10, infinity)),
    ?assertEqual({5, 5}, event_sourcing_interval:new(5, 5)),

    % Test invalid cases - should throw function_clause error due to guard failure
    ?assertError(function_clause, event_sourcing_interval:new(-1, 5)),
    % From > To
    ?assertError(function_clause, event_sourcing_interval:new(5, 3)),
    ?assertError(function_clause, event_sourcing_interval:new(5, -1)).

is_empty_check() ->
    % Test non-empty intervals (half-open [From, To))

    % [0, 10) has 10 elements
    ?assertEqual(false, event_sourcing_interval:is_empty({0, 10})),
    % [5, 6) has 1 element
    ?assertEqual(false, event_sourcing_interval:is_empty({5, 6})),
    ?assertEqual(false, event_sourcing_interval:is_empty({1, infinity})),

    % Test empty intervals (From >= To)

    % [5, 5) is empty
    ?assertEqual(true, event_sourcing_interval:is_empty({5, 5})),
    % [5, 3) is empty
    ?assertEqual(true, event_sourcing_interval:is_empty({5, 3})),
    % [10, 9) is empty
    ?assertEqual(true, event_sourcing_interval:is_empty({10, 9})),

    % Unbounded intervals are never empty
    ?assertEqual(false, event_sourcing_interval:is_empty({0, infinity})),
    ?assertEqual(false, event_sourcing_interval:is_empty({100, infinity})).

advance_interval() ->
    % Test advancing bounded intervals
    Interval1 = event_sourcing_interval:new(0, 10),
    Advanced1 = event_sourcing_interval:advance(Interval1, 3),
    ?assertEqual({3, 10}, Advanced1),

    % Test advancing unbounded intervals
    Interval2 = event_sourcing_interval:new(5, infinity),
    Advanced2 = event_sourcing_interval:advance(Interval2, 7),
    ?assertEqual({12, infinity}, Advanced2),

    % Test advancing by zero
    Interval3 = event_sourcing_interval:new(2, 8),
    Advanced3 = event_sourcing_interval:advance(Interval3, 0),
    ?assertEqual({2, 8}, Advanced3),

    % Test advancing to boundary (creates empty interval)
    Interval4 = event_sourcing_interval:new(3, 7),
    Advanced4 = event_sourcing_interval:advance(Interval4, 4),
    ?assertEqual({7, 7}, Advanced4),
    ?assertEqual(true, event_sourcing_interval:is_empty(Advanced4)),

    % Test advancing beyond boundary (creates empty interval)
    Interval5 = event_sourcing_interval:new(3, 7),
    Advanced5 = event_sourcing_interval:advance(Interval5, 5),
    ?assertEqual({8, 7}, Advanced5),
    ?assertEqual(true, event_sourcing_interval:is_empty(Advanced5)).

lower_bound_access() ->
    % Test lower bound extraction
    ?assertEqual(0, event_sourcing_interval:lower_bound({0, 10})),
    ?assertEqual(5, event_sourcing_interval:lower_bound({5, infinity})),
    ?assertEqual(7, event_sourcing_interval:lower_bound({7, 8})),
    ?assertEqual(100, event_sourcing_interval:lower_bound({100, 200})).

upper_bound_access() ->
    % Test upper bound extraction
    ?assertEqual(10, event_sourcing_interval:upper_bound({0, 10})),
    ?assertEqual(infinity, event_sourcing_interval:upper_bound({5, infinity})),
    ?assertEqual(8, event_sourcing_interval:upper_bound({7, 8})),
    ?assertEqual(200, event_sourcing_interval:upper_bound({100, 200})).

interval_properties() ->
    % Test that intervals maintain invariants for half-open intervals [From, To)
    Interval1 = event_sourcing_interval:new(0, 10),
    ?assert(
        event_sourcing_interval:lower_bound(Interval1) <
            event_sourcing_interval:upper_bound(Interval1) orelse
            event_sourcing_interval:upper_bound(Interval1) =:= infinity
    ),

    Interval2 = event_sourcing_interval:new(5, infinity),
    ?assert(event_sourcing_interval:lower_bound(Interval2) >= 0),
    ?assert(event_sourcing_interval:upper_bound(Interval2) =:= infinity),

    % Test that advancing preserves the upper bound
    Original = event_sourcing_interval:new(2, 15),
    Advanced = event_sourcing_interval:advance(Original, 3),
    ?assertEqual(
        event_sourcing_interval:upper_bound(Original), event_sourcing_interval:upper_bound(Advanced)
    ).

edge_cases() ->
    % Test single-element interval [0, 1)
    SingleElement = event_sourcing_interval:new(0, 1),
    ?assertEqual(false, event_sourcing_interval:is_empty(SingleElement)),
    ?assertEqual(0, event_sourcing_interval:lower_bound(SingleElement)),
    ?assertEqual(1, event_sourcing_interval:upper_bound(SingleElement)),

    % Test large numbers
    LargeInterval = event_sourcing_interval:new(1000000, 2000000),
    ?assertEqual(false, event_sourcing_interval:is_empty(LargeInterval)),
    AdvancedLarge = event_sourcing_interval:advance(LargeInterval, 500000),
    ?assertEqual({1500000, 2000000}, AdvancedLarge),

    % Test advancing unbounded interval by large amount
    Unbounded = event_sourcing_interval:new(0, infinity),
    AdvancedUnbounded = event_sourcing_interval:advance(Unbounded, 1000000),
    ?assertEqual({1000000, infinity}, AdvancedUnbounded).
