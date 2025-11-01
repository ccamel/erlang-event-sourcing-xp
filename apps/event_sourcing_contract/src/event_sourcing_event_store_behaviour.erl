-module(event_sourcing_event_store_behaviour).
-moduledoc """
Behaviour for **event store backends**.

An event store backend is responsible for durable persistence and ordered retrieval
of domain events. It defines how events are appended to a stream and how they can
be replayed for state reconstruction.

Callbacks:
- `start/0`, `stop/0` — manage the backend's lifecycle
- `append/2` — append events to a stream, ensuring monotonic sequence numbers
- `fold/4` — replay events in order and fold them with a user function

Implementations must guarantee:
- **ordering**: events for a given stream are stored and replayed in strictly increasing
  sequence order
- **atomicity**: either all or none of the events in a batch are persisted
- **immutability**: persisted events must never be modified

Typical implementations include in-memory stores (ETS) and relational databases.
""".

-include("event_sourcing.hrl").

-doc """
Starts the event store, performing any necessary initialization.

This callback is called to prepare the store for operation (e.g., setting up
database connections, initializing in-memory structures). Implementations
should be idempotent, allowing repeated calls without side effects.

Returns `ok` on success. May throw an exception if initialization fails
(e.g., resource unavailable).
""".
-callback start() -> ok.
-doc """
This callback function is used to stop the event store.

The callback should perform any necessary cleanup of the event store.
The function should be idempotent, allowing repeated calls without side effects.

Returns `ok` on success. May throw an exception if cleanup fails
(e.g., resource not found).
""".
-callback stop() -> ok.
-doc """
Append events to an event stream.

This callback appends events to the specified stream, ensuring monotonic ordering
by sequence number. Each event is durably persisted and becomes part of the immutable
event log for the stream.

- StreamId is an atom identifying the event stream (e.g., order-123).
- Events is the list of events to append to the stream. The events provided are unique and all
belong to the same stream.

Returns `ok` on success. May throw an exception if persistence fails (e.g., badarg if the
stream ID is incorrect, duplicate events if the sequence number is not unique).
""".
-callback append(StreamId, Events) -> ok when
    StreamId :: stream_id(),
    Events :: [event()].
-doc """
Retrieves events from a stream and folds them into an accumulator.

This callback fetches events for the given `StreamId` within the specified `Range`,
applies the `FoldFun` to each event in sequence order, and returns the final accumulator.
It's typically used to rebuild application state by replaying events.

- StreamId is an atom identifying the event stream (e.g., order-123).
- FoldFun is a function `fun((Event, AccIn) -> AccOut)` to process each event.
- InitialAcc is the initial accumulator value (e.g., an empty state).
- Range is a sequence range defining which events to retrieve:
  - Use `event_sourcing_range:new(0, infinity)` to replay all events.
  - Use `event_sourcing_range:new(N, infinity)` to replay from checkpoint N.
  - Use `event_sourcing_range:new(M, N)` to replay a specific bounded range.

Returns the final accumulator after folding all events in the range.
""".
-callback fold(StreamId, Fun, Acc0, Range) -> Acc1 when
    StreamId :: stream_id(),
    Fun :: fun((Event :: event(), AccIn) -> AccOut),
    Acc0 :: term(),
    Range :: event_sourcing_range:range(),
    Acc1 :: term(),
    AccIn :: term(),
    AccOut :: term().
