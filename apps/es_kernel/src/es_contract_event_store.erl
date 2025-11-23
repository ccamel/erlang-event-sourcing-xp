-module(es_contract_event_store).
-moduledoc """
Behaviour for **event store backends**.

An event store backend is responsible for durable persistence and ordered retrieval
of domain events. It defines the functional capabilities required to persist and
retrieve events, independent of lifecycle management concerns.

Callbacks:
- `append/2` — append events to a stream, ensuring monotonic sequence numbers
- `fold/4` — replay events in order and fold them with a user function

Implementations must guarantee:
- **ordering**: events for a given stream are stored and replayed in strictly increasing
  sequence order
- **atomicity**: either all or none of the events in a batch are persisted
- **immutability**: persisted events must never be modified

Typical implementations include in-memory stores (ETS) and relational databases.

Note: Backend implementations may provide `start/0` and `stop/0` functions for
lifecycle management, but these are not part of this behaviour contract.
""".
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
    StreamId :: es_contract_event:stream_id(),
    Events :: [es_contract_event:t()].
-doc """
Retrieves events from a stream and folds them into an accumulator.

This callback fetches events for the given `StreamId` within the specified `Range`,
applies the `FoldFun` to each event in sequence order, and returns the final accumulator.
It's typically used to rebuild application state by replaying events.

- StreamId is an atom identifying the event stream (e.g., order-123).
- FoldFun is a function `fun((Event, AccIn) -> AccOut)` to process each event.
- InitialAcc is the initial accumulator value (e.g., an empty state).
- Range is a sequence range defining which events to retrieve:
  - Use `es_contract_range:new(0, infinity)` to replay all events.
  - Use `es_contract_range:new(N, infinity)` to replay from checkpoint N.
  - Use `es_contract_range:new(M, N)` to replay a specific bounded range.

Returns the final accumulator after folding all events in the range.
""".
-callback fold(StreamId, Fun, Acc0, Range) -> Acc1 when
    StreamId :: es_contract_event:stream_id(),
    Fun :: fun((Event :: es_contract_event:t(), AccIn) -> AccOut),
    Acc0 :: term(),
    Range :: es_contract_range:range(),
    Acc1 :: term(),
    AccIn :: term(),
    AccOut :: term().
