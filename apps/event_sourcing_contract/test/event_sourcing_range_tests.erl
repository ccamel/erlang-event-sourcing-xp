-module(event_sourcing_range_tests).

-include_lib("eunit/include/eunit.hrl").

%%% Test suite

suite_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        {"new_range_creation", fun new_range_creation/0},
        {"is_empty_check", fun is_empty_check/0},
        {"advance_range", fun advance_range/0},
        {"lower_bound_access", fun lower_bound_access/0},
        {"upper_bound_access", fun upper_bound_access/0},
        {"range_properties", fun range_properties/0},
        {"edge_cases", fun edge_cases/0}
    ]}.

setup() ->
    ok.

teardown(_) ->
    ok.

%%% Test cases

new_range_creation() ->
    % Test basic range creation [0, 10)
    Range1 = event_sourcing_range:new(0, 10),
    ?assertEqual(0, event_sourcing_range:lower_bound(Range1)),
    ?assertEqual(10, event_sourcing_range:upper_bound(Range1)),
    ?assertEqual(false, event_sourcing_range:is_empty(Range1)),

    % Test unbounded range [5, +∞)
    Range2 = event_sourcing_range:new(5, infinity),
    ?assertEqual(5, event_sourcing_range:lower_bound(Range2)),
    ?assertEqual(infinity, event_sourcing_range:upper_bound(Range2)),
    ?assertEqual(false, event_sourcing_range:is_empty(Range2)),

    % Test non-empty single-element range [7, 8)
    Range3 = event_sourcing_range:new(7, 8),
    ?assertEqual(7, event_sourcing_range:lower_bound(Range3)),
    ?assertEqual(8, event_sourcing_range:upper_bound(Range3)),
    ?assertEqual(false, event_sourcing_range:is_empty(Range3)),

    % Test normalization of empty range [5, 3)
    Range4 = event_sourcing_range:new(5, 3),
    ?assertEqual(3, event_sourcing_range:lower_bound(Range4)),
    ?assertEqual(3, event_sourcing_range:upper_bound(Range4)),
    ?assertEqual(true, event_sourcing_range:is_empty(Range4)),

    % Test invalid range creation
    ?assertError(function_clause, event_sourcing_range:new(-1, 5)),
    ?assertError(function_clause, event_sourcing_range:new(5, -1)).

is_empty_check() ->
    % Test non-empty ranges (half-open [From, To))

    % [0, 10) has 10 elements
    Range1 = event_sourcing_range:new(0, 10),
    ?assertEqual(false, event_sourcing_range:is_empty(Range1)),
    % [5, 6) has 1 element
    Range2 = event_sourcing_range:new(5, 6),
    ?assertEqual(false, event_sourcing_range:is_empty(Range2)),
    Range3 = event_sourcing_range:new(1, infinity),
    ?assertEqual(false, event_sourcing_range:is_empty(Range3)),

    % Test empty ranges (From >= To)

    % [5, 5) is empty
    Range4 = event_sourcing_range:new(5, 5),
    ?assertEqual(true, event_sourcing_range:is_empty(Range4)),
    % [5, 3) is empty
    Range5 = event_sourcing_range:new(5, 3),
    ?assertEqual(true, event_sourcing_range:is_empty(Range5)),
    % [10, 9) is empty
    Range6 = event_sourcing_range:new(10, 9),
    ?assertEqual(true, event_sourcing_range:is_empty(Range6)),

    % Unbounded ranges are never empty
    Range7 = event_sourcing_range:new(0, infinity),
    ?assertEqual(false, event_sourcing_range:is_empty(Range7)),
    Range8 = event_sourcing_range:new(100, infinity),
    ?assertEqual(false, event_sourcing_range:is_empty(Range8)).

advance_range() ->
    % Test advancing bounded ranges
    Range1 = event_sourcing_range:new(0, 10),
    Advanced1 = event_sourcing_range:advance(Range1, 3),
    ?assertEqual(3, event_sourcing_range:lower_bound(Advanced1)),
    ?assertEqual(10, event_sourcing_range:upper_bound(Advanced1)),

    % Test advancing unbounded ranges
    Range2 = event_sourcing_range:new(5, infinity),
    Advanced2 = event_sourcing_range:advance(Range2, 7),
    ?assertEqual(12, event_sourcing_range:lower_bound(Advanced2)),
    ?assertEqual(infinity, event_sourcing_range:upper_bound(Advanced2)),

    % Test advancing by zero
    Range3 = event_sourcing_range:new(2, 8),
    Advanced3 = event_sourcing_range:advance(Range3, 0),
    ?assertEqual(2, event_sourcing_range:lower_bound(Advanced3)),
    ?assertEqual(8, event_sourcing_range:upper_bound(Advanced3)),

    % Test advancing to boundary (creates empty range)
    Range4 = event_sourcing_range:new(3, 7),
    Advanced4 = event_sourcing_range:advance(Range4, 4),
    ?assertEqual(7, event_sourcing_range:lower_bound(Advanced4)),
    ?assertEqual(7, event_sourcing_range:upper_bound(Advanced4)),
    ?assertEqual(true, event_sourcing_range:is_empty(Advanced4)),

    % Test advancing beyond boundary (creates empty range)
    Range5 = event_sourcing_range:new(3, 7),
    Advanced5 = event_sourcing_range:advance(Range5, 5),
    ?assertEqual(8, event_sourcing_range:lower_bound(Advanced5)),
    ?assertEqual(7, event_sourcing_range:upper_bound(Advanced5)),
    ?assertEqual(true, event_sourcing_range:is_empty(Advanced5)).

lower_bound_access() ->
    % Test lower bound extraction
    Range1 = event_sourcing_range:new(0, 10),
    ?assertEqual(0, event_sourcing_range:lower_bound(Range1)),
    Range2 = event_sourcing_range:new(5, infinity),
    ?assertEqual(5, event_sourcing_range:lower_bound(Range2)),
    Range3 = event_sourcing_range:new(7, 8),
    ?assertEqual(7, event_sourcing_range:lower_bound(Range3)),
    Range4 = event_sourcing_range:new(100, 200),
    ?assertEqual(100, event_sourcing_range:lower_bound(Range4)).

upper_bound_access() ->
    % Test upper bound extraction
    Range1 = event_sourcing_range:new(0, 10),
    ?assertEqual(10, event_sourcing_range:upper_bound(Range1)),
    Range2 = event_sourcing_range:new(5, infinity),
    ?assertEqual(infinity, event_sourcing_range:upper_bound(Range2)),
    Range3 = event_sourcing_range:new(7, 8),
    ?assertEqual(8, event_sourcing_range:upper_bound(Range3)),
    Range4 = event_sourcing_range:new(100, 200),
    ?assertEqual(200, event_sourcing_range:upper_bound(Range4)).

range_properties() ->
    % Test that ranges maintain invariants for half-open ranges [From, To)
    Range1 = event_sourcing_range:new(0, 10),
    ?assert(
        event_sourcing_range:lower_bound(Range1) <
            event_sourcing_range:upper_bound(Range1) orelse
            event_sourcing_range:upper_bound(Range1) =:= infinity
    ),

    Range2 = event_sourcing_range:new(5, infinity),
    ?assert(event_sourcing_range:lower_bound(Range2) >= 0),
    ?assert(event_sourcing_range:upper_bound(Range2) =:= infinity),

    % Test that advancing preserves the upper bound
    Original = event_sourcing_range:new(2, 15),
    Advanced = event_sourcing_range:advance(Original, 3),
    ?assertEqual(
        event_sourcing_range:upper_bound(Original), event_sourcing_range:upper_bound(Advanced)
    ).

edge_cases() ->
    % Test single-element range [0, 1)
    SingleElement = event_sourcing_range:new(0, 1),
    ?assertEqual(false, event_sourcing_range:is_empty(SingleElement)),
    ?assertEqual(0, event_sourcing_range:lower_bound(SingleElement)),
    ?assertEqual(1, event_sourcing_range:upper_bound(SingleElement)),

    % Test large numbers
    LargeRange = event_sourcing_range:new(1000000, 2000000),
    ?assertEqual(false, event_sourcing_range:is_empty(LargeRange)),
    AdvancedLarge = event_sourcing_range:advance(LargeRange, 500000),
    ?assertEqual(1500000, event_sourcing_range:lower_bound(AdvancedLarge)),
    ?assertEqual(2000000, event_sourcing_range:upper_bound(AdvancedLarge)),

    % Test advancing unbounded range by large amount
    Unbounded = event_sourcing_range:new(0, infinity),
    AdvancedUnbounded = event_sourcing_range:advance(Unbounded, 1000000),
    ?assertEqual(1000000, event_sourcing_range:lower_bound(AdvancedUnbounded)),
    ?assertEqual(infinity, event_sourcing_range:upper_bound(AdvancedUnbounded)).
