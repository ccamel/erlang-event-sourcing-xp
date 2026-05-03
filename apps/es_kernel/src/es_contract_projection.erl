-module(es_contract_projection).
-moduledoc """
Defines the projection behaviour for building read models from event streams.

Modules implementing this behaviour encapsulate the logic for consuming
events and maintaining derived state (read models, materialized views, etc.).
Projections are the read-side of a CQRS architecture, complementing the
write-side aggregates.

Projections are event handlers that:
- Process events in order to build read-optimized views
- Maintain their own state independent of aggregates
- Can subscribe to specific event streams or all events
- Track their position in the event stream for resumability

Implementers are responsible for:

- Initializing projection state (`init/0`)
- Processing events and updating state (`handle_event/2`)
- Providing a unique projection identifier (`name/0`)
- Optionally filtering events to process (`event_filter/1`)

## Example

```erlang
-module(account_balance_projection).
-behaviour(es_contract_projection).

-export([init/0, handle_event/2, name/0, event_filter/1]).

init() ->
    #{balances => #{}}.

handle_event(#{type := deposited, payload := #{account_id := Id, amount := Amount}},
             #{balances := Balances} = State) ->
    CurrentBalance = maps:get(Id, Balances, 0),
    {ok, State#{balances => Balances#{Id => CurrentBalance + Amount}}};
handle_event(#{type := withdrawn, payload := #{account_id := Id, amount := Amount}},
             #{balances := Balances} = State) ->
    CurrentBalance = maps:get(Id, Balances, 0),
    {ok, State#{balances => Balances#{Id => CurrentBalance - Amount}}};
handle_event(_Event, State) ->
    {ok, State}.

name() ->
    account_balance_projection.

event_filter(#{aggregate_type := account}) -> true;
event_filter(_) -> false.
```
""".

-export_type([projection_state/0, event_filter/0]).

-type projection_state() :: term().

-doc """
Predicate function that determines whether an event should be processed.

Returns `true` if the event should be handled, `false` to skip it.
""".
-type event_filter() :: fun((es_contract_event:t()) -> boolean()).

-doc """
Initialize the projection's state.

This is called once when the projection process is started and before
any events have been processed.

Returns the initial projection state.
""".
-callback init() -> projection_state().

-doc """
Return the unique name for this projection.

This name is used to:
- Identify the projection in the system
- Track checkpoint position for resumability
- Register the projection in the manager

The name must be unique across all projections in the system and should
be stable across restarts.

Returns a unique atom identifier for this projection.
""".
-callback name() -> atom().

-doc """
Process an event and update the projection state.

This function is called for each event that passes the filter (if defined).
It receives the current projection state and returns either:

- `{ok, NewState}` — The updated projection state
- `{error, Reason}` — An error occurred processing the event

This function should be deterministic for idempotency. Since events may be
replayed during recovery or reprocessed due to failures, the projection
should handle duplicate events gracefully.

Side effects (database writes, external API calls, etc.) are allowed here,
unlike in aggregate callbacks. However, consider idempotency carefully.

- Event is the domain event to process
- State is the current projection state

Returns the result of processing the event.
""".
-callback handle_event(Event, State) ->
    {ok, NewState} | {error, Reason}
when
    Event :: es_contract_event:t(),
    State :: projection_state(),
    NewState :: projection_state(),
    Reason :: term().

-doc """
Filter events to determine which ones this projection should process.

This optional callback allows projections to subscribe to a subset of events
rather than all events in the system. If not implemented, the projection
will process all events.

Common filtering strategies:
- By aggregate type: `#{aggregate_type := account} -> true`
- By event type: `#{type := user_created} -> true`
- By stream pattern: `#{stream_id := {user, _}} -> true`
- By tags: Check if event has specific tags
- Combined criteria: Multiple conditions

Returns `true` if the event should be processed, `false` to skip it.

Note: This is an optional callback. If not implemented, all events are processed.
""".
-callback event_filter(Event) -> ShouldProcess when
    Event :: es_contract_event:t(),
    ShouldProcess :: boolean().

-optional_callbacks([event_filter/1]).
