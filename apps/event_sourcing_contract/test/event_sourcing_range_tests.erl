-module(event_sourcing_range_tests).

-include_lib("eunit/include/eunit.hrl").

%%% Test suite

suite_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        {"new_range_creation", fun new_range_creation/0},
        {"is_empty_check", fun is_empty_check/0},
        {"equal_check", fun equal_check/0},
        {"contain_check", fun contain_check/0},
        {"overlap_check", fun overlap_check/0},
        {"intersection_check", fun intersection_check/0},
        {"lt_check", fun lt_check/0},
        {"difference_check", fun difference_check/0},
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
    ?assertError(function_clause, event_sourcing_range:new(5, -1)),
    ?assertError(
        {invalid_range, infinity_lower_bound}, event_sourcing_range:new(infinity, infinity)
    ).

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

equal_check() ->
    % Identical bounded ranges
    Range1 = event_sourcing_range:new(0, 10),
    Range2 = event_sourcing_range:new(0, 10),
    ?assertEqual(true, event_sourcing_range:equal(Range1, Range2)),

    % Identical unbounded ranges
    Range3 = event_sourcing_range:new(5, infinity),
    Range4 = event_sourcing_range:new(5, infinity),
    ?assertEqual(true, event_sourcing_range:equal(Range3, Range4)),

    % Lower bound differs
    Range5 = event_sourcing_range:new(1, 10),
    ?assertEqual(false, event_sourcing_range:equal(Range1, Range5)),

    % Upper bound differs
    Range6 = event_sourcing_range:new(0, infinity),
    ?assertEqual(false, event_sourcing_range:equal(Range1, Range6)),

    % Normalized empty ranges compare on normalized bounds
    Range7 = event_sourcing_range:new(5, 3),
    Range8 = event_sourcing_range:new(4, 2),
    ?assertEqual(true, event_sourcing_range:equal(Range7, Range8)),

    % Empty versus non-empty
    Range9 = event_sourcing_range:new(3, 3),
    Range10 = event_sourcing_range:new(3, 4),
    ?assertEqual(false, event_sourcing_range:equal(Range9, Range10)).

contain_check() ->
    Outer1 = event_sourcing_range:new(2, 10),
    Inner1 = event_sourcing_range:new(4, 8),
    ?assertEqual(true, event_sourcing_range:contain(Outer1, Inner1)),

    % Exact match
    ?assertEqual(true, event_sourcing_range:contain(Outer1, Outer1)),

    % Lower bound outside
    Inner2 = event_sourcing_range:new(1, 5),
    ?assertEqual(false, event_sourcing_range:contain(Outer1, Inner2)),

    % Upper bound outside
    Inner3 = event_sourcing_range:new(5, 12),
    ?assertEqual(false, event_sourcing_range:contain(Outer1, Inner3)),

    % Empty inner range always contained
    InnerEmpty = event_sourcing_range:new(5, 3),
    ?assertEqual(true, event_sourcing_range:contain(Outer1, InnerEmpty)),

    % Empty outer cannot contain non-empty range
    OuterEmpty = event_sourcing_range:new(7, 4),
    ?assertEqual(false, event_sourcing_range:contain(OuterEmpty, Inner1)),

    % Unbounded outer
    OuterUnbounded = event_sourcing_range:new(0, infinity),
    InnerUnbounded = event_sourcing_range:new(5, infinity),
    ?assertEqual(true, event_sourcing_range:contain(OuterUnbounded, InnerUnbounded)),

    % Unbounded inner requires unbounded outer
    InnerUnbounded2 = event_sourcing_range:new(5, infinity),
    ?assertEqual(false, event_sourcing_range:contain(Outer1, InnerUnbounded2)).

overlap_check() ->
    % Test overlapping bounded ranges
    Range1 = event_sourcing_range:new(0, 10),
    Range2 = event_sourcing_range:new(5, 15),
    ?assertEqual(true, event_sourcing_range:overlap(Range1, Range2)),

    % Test non-overlapping bounded ranges
    Range3 = event_sourcing_range:new(0, 5),
    Range4 = event_sourcing_range:new(5, 10),
    ?assertEqual(false, event_sourcing_range:overlap(Range3, Range4)),

    % Test one contains the other
    Range5 = event_sourcing_range:new(0, 10),
    Range6 = event_sourcing_range:new(2, 8),
    ?assertEqual(true, event_sourcing_range:overlap(Range5, Range6)),

    % Test adjacent ranges (touching but not overlapping)
    Range7 = event_sourcing_range:new(0, 5),
    Range8 = event_sourcing_range:new(5, 10),
    ?assertEqual(false, event_sourcing_range:overlap(Range7, Range8)),

    % Test empty ranges
    Empty1 = event_sourcing_range:new(5, 3),
    Range9 = event_sourcing_range:new(0, 10),
    ?assertEqual(false, event_sourcing_range:overlap(Empty1, Range9)),
    ?assertEqual(false, event_sourcing_range:overlap(Range9, Empty1)),

    % Test unbounded ranges
    Unbounded1 = event_sourcing_range:new(0, infinity),
    Range10 = event_sourcing_range:new(5, 10),
    ?assertEqual(true, event_sourcing_range:overlap(Unbounded1, Range10)),

    Unbounded2 = event_sourcing_range:new(10, infinity),
    Range11 = event_sourcing_range:new(0, 5),
    ?assertEqual(false, event_sourcing_range:overlap(Unbounded2, Range11)),

    Unbounded3 = event_sourcing_range:new(5, infinity),
    ?assertEqual(true, event_sourcing_range:overlap(Unbounded1, Unbounded3)),

    % Test bounded with unbounded
    Range12 = event_sourcing_range:new(0, 10),
    Unbounded4 = event_sourcing_range:new(5, infinity),
    ?assertEqual(true, event_sourcing_range:overlap(Range12, Unbounded4)),

    Range13 = event_sourcing_range:new(10, 15),
    ?assertEqual(true, event_sourcing_range:overlap(Range13, Unbounded4)),

    % Test identical ranges
    ?assertEqual(true, event_sourcing_range:overlap(Range1, Range1)).

intersection_check() ->
    % Test overlapping bounded ranges
    Range1 = event_sourcing_range:new(0, 10),
    Range2 = event_sourcing_range:new(5, 15),
    Intersection1 = event_sourcing_range:intersection(Range1, Range2),
    ?assertEqual(5, event_sourcing_range:lower_bound(Intersection1)),
    ?assertEqual(10, event_sourcing_range:upper_bound(Intersection1)),

    % Test non-overlapping bounded ranges
    Range3 = event_sourcing_range:new(0, 5),
    Range4 = event_sourcing_range:new(5, 10),
    Intersection2 = event_sourcing_range:intersection(Range3, Range4),
    ?assertEqual(true, event_sourcing_range:is_empty(Intersection2)),

    % Test one contains the other
    Range5 = event_sourcing_range:new(0, 10),
    Range6 = event_sourcing_range:new(2, 8),
    Intersection3 = event_sourcing_range:intersection(Range5, Range6),
    ?assertEqual(2, event_sourcing_range:lower_bound(Intersection3)),
    ?assertEqual(8, event_sourcing_range:upper_bound(Intersection3)),

    % Test empty ranges
    Empty1 = event_sourcing_range:new(5, 3),
    Range9 = event_sourcing_range:new(0, 10),
    Intersection4 = event_sourcing_range:intersection(Empty1, Range9),
    ?assertEqual(true, event_sourcing_range:is_empty(Intersection4)),

    % Test unbounded ranges
    Unbounded1 = event_sourcing_range:new(0, infinity),
    Range10 = event_sourcing_range:new(5, 10),
    Intersection5 = event_sourcing_range:intersection(Unbounded1, Range10),
    ?assertEqual(5, event_sourcing_range:lower_bound(Intersection5)),
    ?assertEqual(10, event_sourcing_range:upper_bound(Intersection5)),

    Unbounded2 = event_sourcing_range:new(10, infinity),
    Range11 = event_sourcing_range:new(0, 5),
    Intersection6 = event_sourcing_range:intersection(Unbounded2, Range11),
    ?assertEqual(true, event_sourcing_range:is_empty(Intersection6)),

    Unbounded3 = event_sourcing_range:new(5, infinity),
    Intersection7 = event_sourcing_range:intersection(Unbounded1, Unbounded3),
    ?assertEqual(5, event_sourcing_range:lower_bound(Intersection7)),
    ?assertEqual(infinity, event_sourcing_range:upper_bound(Intersection7)),

    % Test identical ranges
    Intersection8 = event_sourcing_range:intersection(Range1, Range1),
    ?assertEqual(0, event_sourcing_range:lower_bound(Intersection8)),
    ?assertEqual(10, event_sourcing_range:upper_bound(Intersection8)).

lt_check() ->
    % Test lower bound comparison
    Range1 = event_sourcing_range:new(0, 10),
    Range2 = event_sourcing_range:new(5, 10),
    ?assertEqual(true, event_sourcing_range:lt(Range1, Range2)),
    ?assertEqual(false, event_sourcing_range:lt(Range2, Range1)),

    % Test upper bound comparison when lower bounds equal
    Range3 = event_sourcing_range:new(5, 10),
    Range4 = event_sourcing_range:new(5, 15),
    ?assertEqual(false, event_sourcing_range:lt(Range3, Range4)),
    ?assertEqual(false, event_sourcing_range:lt(Range4, Range3)),

    % Test equal ranges
    Range5 = event_sourcing_range:new(5, 10),
    Range6 = event_sourcing_range:new(5, 10),
    ?assertEqual(false, event_sourcing_range:lt(Range5, Range6)),
    ?assertEqual(false, event_sourcing_range:lt(Range6, Range5)),

    % Test with infinity
    Range7 = event_sourcing_range:new(5, 10),
    Range8 = event_sourcing_range:new(5, infinity),
    ?assertEqual(false, event_sourcing_range:lt(Range7, Range8)),
    ?assertEqual(false, event_sourcing_range:lt(Range8, Range7)),

    Range9 = event_sourcing_range:new(5, infinity),
    Range10 = event_sourcing_range:new(5, infinity),
    ?assertEqual(false, event_sourcing_range:lt(Range9, Range10)),

    % Test different lower bounds with infinity
    Range11 = event_sourcing_range:new(0, infinity),
    Range12 = event_sourcing_range:new(5, infinity),
    ?assertEqual(true, event_sourcing_range:lt(Range11, Range12)),
    ?assertEqual(false, event_sourcing_range:lt(Range12, Range11)),

    % Test empty ranges
    Empty1 = event_sourcing_range:new(5, 5),
    Empty2 = event_sourcing_range:new(5, 5),
    ?assertEqual(false, event_sourcing_range:lt(Empty1, Empty2)),

    Range13 = event_sourcing_range:new(0, 5),
    ?assertEqual(false, event_sourcing_range:lt(Range13, Empty1)),
    ?assertEqual(false, event_sourcing_range:lt(Empty1, Range13)).

difference_check() ->
    % Test empty RangeA
    EmptyA = event_sourcing_range:new(5, 5),
    Range1 = event_sourcing_range:new(0, 10),
    ?assertEqual([], event_sourcing_range:difference(EmptyA, Range1)),

    % Test empty RangeB
    ?assertEqual([Range1], event_sourcing_range:difference(Range1, EmptyA)),

    % Test no overlap
    Range2 = event_sourcing_range:new(10, 20),
    ?assertEqual([Range1], event_sourcing_range:difference(Range1, Range2)),

    % Test RangeB fully covers RangeA
    Range3 = event_sourcing_range:new(0, 10),
    ?assertEqual([], event_sourcing_range:difference(Range1, Range3)),

    % Test RangeB overlaps start of RangeA
    Range4 = event_sourcing_range:new(5, 15),
    Diff1 = event_sourcing_range:difference(Range1, Range4),
    ?assertEqual(1, length(Diff1)),
    [D1] = Diff1,
    ?assertEqual(0, event_sourcing_range:lower_bound(D1)),
    ?assertEqual(5, event_sourcing_range:upper_bound(D1)),

    % Test RangeB overlaps end of RangeA
    Range5 = event_sourcing_range:new(0, 5),
    Diff2 = event_sourcing_range:difference(Range1, Range5),
    ?assertEqual(1, length(Diff2)),
    [D2] = Diff2,
    ?assertEqual(5, event_sourcing_range:lower_bound(D2)),
    ?assertEqual(10, event_sourcing_range:upper_bound(D2)),

    % Test RangeB in middle of RangeA
    Range6 = event_sourcing_range:new(3, 7),
    Diff3 = event_sourcing_range:difference(Range1, Range6),
    ?assertEqual(2, length(Diff3)),
    [D3a, D3b] = Diff3,
    ?assertEqual(0, event_sourcing_range:lower_bound(D3a)),
    ?assertEqual(3, event_sourcing_range:upper_bound(D3a)),
    ?assertEqual(7, event_sourcing_range:lower_bound(D3b)),
    ?assertEqual(10, event_sourcing_range:upper_bound(D3b)),

    % Test with unbounded ranges
    UnboundedA = event_sourcing_range:new(0, infinity),
    Range7 = event_sourcing_range:new(5, 10),
    Diff4 = event_sourcing_range:difference(UnboundedA, Range7),
    ?assertEqual(2, length(Diff4)),
    [D4a, D4b] = Diff4,
    ?assertEqual(0, event_sourcing_range:lower_bound(D4a)),
    ?assertEqual(5, event_sourcing_range:upper_bound(D4a)),
    ?assertEqual(10, event_sourcing_range:lower_bound(D4b)),
    ?assertEqual(infinity, event_sourcing_range:upper_bound(D4b)).

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
    ?assertEqual(7, event_sourcing_range:lower_bound(Advanced5)),
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
