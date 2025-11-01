-module(event_sourcing_interval).
-moduledoc """
Algebraic data type for representing sequence intervals with lower and upper bounds.
Supports both bounded intervals `[From, To)` and unbounded intervals `[From, +∞)`.

Intervals are half-open: they include the lower bound but exclude the upper bound.
""".

-export([
    new/2,
    is_empty/1,
    advance/2,
    lower_bound/1,
    upper_bound/1
]).

-export_type([interval/0]).

-type interval() :: {non_neg_integer(), non_neg_integer() | infinity}.

-doc """
Create a new interval with the given lower and upper bounds.
Upper bound can be `infinity` for unbounded intervals.

The interval is half-open: [From, To) includes From but excludes To.
""".
-spec new(non_neg_integer(), non_neg_integer() | infinity) -> interval().
new(From, To) when
    From >= 0,
    (is_integer(To) andalso To >= From) orelse To =:= infinity
->
    {From, To}.

-doc """
Check if an interval is empty.
An interval [From, To) is empty when From >= To.
Unbounded intervals (with upper bound = infinity) are never empty.
""".
-spec is_empty(interval()) -> boolean().
is_empty({From, infinity}) when From >= 0 ->
    false;
is_empty({From, To}) when is_integer(From), is_integer(To) ->
    From >= To.

-doc """
Advance the interval by moving the lower bound forward by the given amount.
Returns the new interval.
""".
-spec advance(interval(), non_neg_integer()) -> interval().
advance({From, To}, N) when N >= 0 ->
    {From + N, To}.

-doc """
Get the lower bound of the interval.
""".
-spec lower_bound(interval()) -> non_neg_integer().
lower_bound({From, _To}) ->
    From.

-doc """
Get the upper bound of the interval.
""".
-spec upper_bound(interval()) -> non_neg_integer() | infinity.
upper_bound({_From, To}) ->
    To.
