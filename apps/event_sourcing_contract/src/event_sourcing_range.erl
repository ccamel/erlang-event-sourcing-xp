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
Create a new half-open range `[From, To)`.

If `To = infinity`, the range is unbounded above.
If `From > To` (when `To` is finite), the range is normalized to an empty range `{To, To}`.
`From` must be finite — `new(infinity, _)` is invalid.
""".
-spec new(non_neg_integer(), non_neg_integer() | infinity) -> range().
new(From, infinity) when is_integer(From), From >= 0 ->
    {From, infinity};
new(infinity, _) ->
    error({invalid_interval, infinity_lower_bound});
new(From, To) when is_integer(From), is_integer(To), From >= 0, To >= 0 ->
    case From =< To of
        true  -> {From, To};
        false -> {To, To}
    end.

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
