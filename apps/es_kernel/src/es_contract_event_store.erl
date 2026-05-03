-module(es_contract_event_store).

-export_type([position/0]).

-doc """
Global position of an event in the event store log.

Positions are assigned by storage backends and are not part of the domain event
payload. They are monotonically increasing within a backend instance.
""".
-type position() :: non_neg_integer().

-moduledoc """
Behaviour for event store backends.

An event store backend is responsible for durable persistence and ordered retrieval
of domain events. It defines the functional capabilities required to persist and
retrieve events, independent of lifecycle management concerns.

Callbacks:
- `append/2` - append events to a stream, ensuring monotonic sequence numbers
- `fold/4` - replay events of a single stream in order and fold them with a user function
- `fold_all/3` - replay events from the global event log in position order and fold them

Implementations must guarantee:

- ordering: events for a given stream are stored and replayed in strictly increasing
  sequence order
- atomicity: either all or none of the events in a batch are persisted
- immutability: persisted events must never be modified

Typical implementations include in-memory stores (ETS) and relational databases.

Note: backend implementations may provide `start/0` and `stop/0` functions for
lifecycle management, but these are not part of this behaviour contract.
""".

-doc """
Append events to an event stream.

This callback appends events to the specified stream, ensuring monotonic ordering
by sequence number. Each event is durably persisted and becomes part of the immutable
event log for the stream.

- StreamId identifies the event stream (for example `{order, <<"123">>}`).
- Events is the list of events to append to the stream.

The kernel guarantees that:

- all events in the batch belong to the same stream
- the `stream_id()` carried by each event is equal to `StreamId`

Backends MAY rely on these invariants and are not required to re validate them.

On success, implementations MUST return `ok`.

On failure, implementations MUST return `{error, Reason}` and MUST guarantee that
no partial batch is ever visible. Exceptions SHOULD be reserved for programmer
errors or unrecoverable failures.
""".
-callback append(StreamId, Events) ->
    ok | {error, Reason}
when
    StreamId :: es_contract_event:stream_id(),
    Events :: [es_contract_event:t()],
    Reason :: term().
-doc """
Retrieves events from a single stream and folds them into an accumulator.

This callback fetches events for the given `StreamId` within the specified sequence
`Range`, applies `FoldFun` to each event in sequence order, and returns the final
accumulator. It is typically used to rebuild aggregate state by replaying events.

- StreamId identifies the event stream.
 - FoldFun is a function `fun((Event, Sequence, AccIn) -> AccOut)` to process each event
   together with its sequence number in the stream.
- InitialAcc is the initial accumulator value (for example an empty state).
- Range is a sequence range defining which events to retrieve:
  - `es_contract_range:new(0, infinity)` to replay all events
  - `es_contract_range:new(N, infinity)` to replay from sequence N
  - `es_contract_range:new(M, N)` to replay a bounded sequence range

If the range is empty, implementations MUST return `{ok, InitialAcc}`.

On success, returns `{ok, Acc1}` where `Acc1` is the final accumulator.
On failure, implementations MUST return `{error, Reason}`.
Exceptions SHOULD be reserved for programmer errors or unrecoverable failures.
""".
-callback fold(StreamId, FoldFun, Acc0, Range) ->
    {ok, Acc1} | {error, Reason}
when
    StreamId :: es_contract_event:stream_id(),
    FoldFun :: fun(
        (
            Event :: es_contract_event:t(),
            Sequence :: es_contract_event:sequence(),
            AccIn
        ) -> AccOut
    ),
    Acc0 :: term(),
    Range :: es_contract_range:range(),
    Acc1 :: term(),
    AccIn :: term(),
    AccOut :: term(),
    Reason :: term().

-doc """
Retrieves events from the global event log and folds them into an accumulator.

This callback is intended for projections and subscriptions on the read side
of a CQRS architecture. Unlike `fold/4`, which operates on a single stream
and uses sequence ranges, this function operates on the global event log and
uses position ranges.

Each persisted event is assigned a monotonically increasing global position
(offset) when written. This position enables:

- catch-up subscriptions (replay from position N)
- projection checkpointing (resume processing from last position)
- global event ordering for read models
- cross-aggregate queries

- FoldFun is a function `fun((Event, Position, AccIn) -> AccOut)` to process
  each event with its global position.
- InitialAcc is the initial accumulator value.
- Range is a position range (not a sequence range) defining which events to retrieve.
  Implementations MUST interpret this range in terms of global positions.


On success, returns `{ok, Acc1}` where `Acc1` is the final accumulator.
On failure, implementations MUST return `{error, Reason}`.
Exceptions SHOULD be reserved for programmer errors or unrecoverable failures.
""".
-callback fold_all(FoldFun, Acc0, Range) ->
    {ok, Acc1} | {error, Reason}
when
    FoldFun :: fun(
        (
            Event :: es_contract_event:t(),
            Position :: position(),
            AccIn
        ) -> AccOut
    ),
    Acc0 :: term(),
    %% position-based range
    Range :: es_contract_range:range(),
    Acc1 :: term(),
    AccIn :: term(),
    AccOut :: term(),
    Reason :: term().
