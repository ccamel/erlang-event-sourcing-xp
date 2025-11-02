-module(event_sourcing_range).
-moduledoc """
Algebraic data type for representing sequence ranges with lower and upper bounds.
Supports both bounded ranges `[From, To)` and unbounded ranges `[From, +∞)`.

Ranges are half-open: they include the lower bound but exclude the upper bound.
""".

-export([
    new/2,
    is_empty/1,
    equal/2,
    contain/2,
    overlap/2,
    intersection/2,
    lt/2,
    difference/2,
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
    error({invalid_range, infinity_lower_bound});
new(From, To) when is_integer(From), is_integer(To), From >= 0, To >= 0 ->
    case From =< To of
        true -> {From, To};
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
Check whether two ranges are equal.
Ranges are equal when both their lower and upper bounds match.
Empty ranges compare equal regardless of their normalized bounds.
""".
-spec equal(range(), range()) -> boolean().
equal({FromA, ToA} = RangeA, {FromB, ToB} = RangeB) ->
    case {FromA =:= FromB, ToA =:= ToB} of
        {true, true} ->
            true;
        _ ->
            is_empty(RangeA) andalso is_empty(RangeB)
    end.

-doc """
Check whether `RangeA` is strictly less than `RangeB`.
This holds when the lower bound of `RangeA` is less than the lower bound of `RangeB`.
""".
-spec lt(range(), range()) -> boolean().
lt(A, B) ->
    case {is_empty(A), is_empty(B)} of
        {true, _} ->
            false;
        {_, true} ->
            false;
        _ ->
            {FromA, _} = A,
            {FromB, _} = B,
            FromA < FromB
    end.

-doc """
Check whether `Outer` fully contain `Inner`.
Empty ranges are contained by any range.
""".
-spec contain(range(), range()) -> boolean().
contain(Outer, Inner) ->
    case is_empty(Inner) of
        true ->
            true;
        false ->
            {FromOuter, ToOuter} = Outer,
            {FromInner, ToInner} = Inner,
            LowerOk = FromOuter =< FromInner,
            UpperOk =
                case {ToOuter, ToInner} of
                    {infinity, _} ->
                        true;
                    {_, infinity} ->
                        false;
                    _ ->
                        ToOuter >= ToInner
                end,
            LowerOk andalso UpperOk
    end.

-doc """
Check whether two range overlap.

For half-open range `[A1, A2)` and `[B1, B2)`, they overlap when:
- `A1 < B2` and
- `B1 < A2`.

Unbounded range (`To = infinity`) overlap any range that starts before their infinity.
""".
-spec overlap(range(), range()) -> boolean().
overlap(RangeA, RangeB) ->
    {FromA, ToA} = RangeA,
    {FromB, ToB} = RangeB,
    not (is_empty(RangeA) orelse is_empty(RangeB)) andalso
        (FromA < ToB orelse ToB =:= infinity) andalso
        (FromB < ToA orelse ToA =:= infinity).

-doc """
Compute the intersection of two ranges.
Returns the overlapping range if they overlap, otherwise an empty range.
""".
-spec intersection(range(), range()) -> range().
intersection({FromA, ToA}, {FromB, ToB}) ->
    Lower = max(FromA, FromB),
    Upper =
        case {ToA, ToB} of
            {infinity, infinity} -> infinity;
            {infinity, _} -> ToB;
            {_, infinity} -> ToA;
            _ -> min(ToA, ToB)
        end,
    case Lower < Upper orelse Upper =:= infinity of
        true -> {Lower, Upper};
        % empty
        false -> {Upper, Upper}
    end.

-doc """
Compute the difference between two ranges: `RangeA - RangeB`.
Returns a list of ranges representing the parts of `RangeA` that are not covered by `RangeB`.
If `RangeB` fully covers `RangeA`, the result is an empty list.
""".
-spec difference(range(), range()) -> [range()].
difference(RangeA, RangeB) ->
    case {is_empty(RangeA), is_empty(RangeB)} of
        {true, _} ->
            [];
        {_, true} ->
            [RangeA];
        _ ->
            difference_non_empty(RangeA, RangeB)
    end.

difference_non_empty(RangeA, RangeB) ->
    case overlap(RangeA, RangeB) of
        false ->
            [RangeA];
        true ->
            case contain(RangeB, RangeA) of
                true ->
                    [];
                false ->
                    difference_partial(RangeA, RangeB)
            end
    end.

difference_partial({AF, AT}, {BF, BT}) ->
    case BF =< AF of
        true ->
            Tail = {BT, AT},
            case is_empty(Tail) of
                true -> [];
                false -> [Tail]
            end;
        false ->
            Head = {AF, BF},
            Tail = {BT, AT},
            lists:filter(fun(R) -> not is_empty(R) end, [Head, Tail])
    end.

-doc """
Advance the range by moving the lower bound forward by the given amount.
If the advancement would make the range empty, returns an empty range.
""".
-spec advance(range(), non_neg_integer()) -> range().
advance({From, infinity}, N) when N >= 0 ->
    {From + N, infinity};
advance({From, To}, N) when N >= 0, is_integer(To) ->
    NewFrom = From + N,
    case NewFrom < To of
        true -> {NewFrom, To};
        false -> {To, To}
    end.

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
