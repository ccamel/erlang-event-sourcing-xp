-module(event_sourcing_range).
-moduledoc """
Algebraic data type for representing sequence ranges with lower and upper bounds.
Supports both bounded ranges `[From, To)` and unbounded ranges `[From, +∞)`.

Ranges are half-open: they include the lower bound but exclude the upper bound.
""".

-export([
    new/2,
    is_empty/1,
    advance/2,
    lower_bound/1,
    upper_bound/1
]).

-export_type([range/0]).

-type range() :: {non_neg_integer(), non_neg_integer() | infinity}.

-doc """
Create a new range with the given lower and upper bounds.
Upper bound can be `infinity` for unbounded ranges.

The range is half-open: [From, To) includes From but excludes To.
""".
-spec new(non_neg_integer(), non_neg_integer() | infinity) -> range().
new(From, To) when
    From >= 0,
    (is_integer(To) andalso To >= From) orelse To =:= infinity
->
    {From, To}.

-doc """
Check if a range is empty.
A range [From, To) is empty when From >= To.
Unbounded ranges (with upper bound = infinity) are never empty.
""".
-spec is_empty(range()) -> boolean().
is_empty({From, infinity}) when From >= 0 ->
    false;
is_empty({From, To}) when is_integer(From), is_integer(To) ->
    From >= To.

-doc """
Advance the range by moving the lower bound forward by the given amount.
Returns the new range.
""".
-spec advance(range(), non_neg_integer()) -> range().
advance({From, To}, N) when N >= 0 ->
    {From + N, To}.

-doc """
Get the lower bound of the range.
""".
-spec lower_bound(range()) -> non_neg_integer().
lower_bound({From, _To}) ->
    From.

-doc """
Get the upper bound of the range.
""".
-spec upper_bound(range()) -> non_neg_integer() | infinity.
upper_bound({_From, To}) ->
    To.
