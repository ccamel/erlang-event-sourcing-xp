-module(es_contract_projection).
-moduledoc """
Defines the projection behaviour for building read models from event streams.

Modules implementing this behaviour encapsulate the logic for consuming
events and maintaining derived state (read models, materialized views, etc.).
Projections are the read-side of a CQRS architecture, complementing the
write-side aggregates.

Projections consume global-log events in position order to maintain a derived,
rebuildable, query-oriented view. Their callback state is opaque to the runtime:
it can be an in-memory view, a repository or database session, a client, or
batching and caching context.

The state is not checkpointed by the runtime. A projection that needs recovery
across runner or VM restarts must make its view durable itself. Projections are
not intended for arbitrary reactions such as emails, webhooks, or commands.

Implementers are responsible for:

- Initializing projection state (`init/0`)
- Processing selected events and maintaining the view (`handle_event/3`)
- Providing a unique projection identifier (`name/0`) for continuous consumers
- Optionally filtering events to process (`event_filter/1`)

## Example

```erlang
-module(account_balance_projection).
-behaviour(es_contract_projection).

-export([init/0, handle_event/3, name/0, event_filter/1]).

init() ->
    #{balances => #{}}.

handle_event(
    #{type := deposited, payload := #{account_id := Id, amount := Amount}},
    _Position,
    #{balances := Balances} = State
) ->
    CurrentBalance = maps:get(Id, Balances, 0),
    {ok, State#{balances => Balances#{Id => CurrentBalance + Amount}}};
handle_event(
    #{type := withdrawn, payload := #{account_id := Id, amount := Amount}},
    _Position,
    #{balances := Balances} = State
) ->
    CurrentBalance = maps:get(Id, Balances, 0),
    {ok, State#{balances => Balances#{Id => CurrentBalance - Amount}}};
handle_event(_Event, _Position, State) ->
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
Initialize the projection's callback state.

The runtime treats this value as opaque and never persists it. `run_once/3`
returns it as the materialized view; continuous projections must make any view
that must survive recovery durable before returning `{ok, NewState}`.
""".
-callback init() -> projection_state().

-doc """
Return the stable unique name for a continuous projection.

The continuous runner uses this name as its checkpoint key and the manager uses
it to identify the runner. It must remain stable across restarts.
""".
-callback name() -> atom().

-doc """
Apply a selected global-log event to the projection's derived view.

`Position` is the event's global position. For a continuous projection,
returning `{ok, NewState}` means the view mutation has reached the projection's
required durability level. The runner commits that position only afterwards.
If it crashes after the mutation and before the checkpoint commit, the event is
delivered again; projections must therefore make targeted mutations idempotent
or deduplicate them using `Position`.

`run_once/3` uses this callback as an independent fold and does not load or
write checkpoints. Continuous runners never persist arbitrary callback state
and provide at-least-once delivery, not exactly-once semantics across stores.

Returns either `{ok, NewState}` or `{error, Reason}`.
""".
-callback handle_event(Event, Position, State) ->
    {ok, NewState} | {error, Reason}
when
    Event :: es_contract_event:t(),
    Position :: es_contract_event_store:position(),
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
