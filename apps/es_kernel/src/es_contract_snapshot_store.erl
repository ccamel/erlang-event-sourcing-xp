-module(es_contract_snapshot_store).
-moduledoc """
Behaviour for **snapshot store backends**.

A snapshot store backend handles persistence of aggregate snapshots — condensed
representations of the state after applying a set of events.

Callbacks:
- `start/0`, `stop/0` — manage backend initialization and shutdown
- `store/1` — persist a snapshot of the aggregate state
- `load_latest/1` — fetch the most recent snapshot for a given stream

Design principles:
- Snapshots are **optional optimizations**; events remain the source of truth.
- Backends should prefer returning `{warning, Reason}` instead of crashing when persistence fails.
- Each stream typically holds only its latest snapshot, though implementations
  may store historical versions if needed.

Common implementations include key–value stores, databases, or object storage
systems (e.g., S3).
""".

-doc """
Store a snapshot for a stream.

This callback persists a snapshot of the aggregate state at a specific point in time,
representing the state after applying all events up to and including the recorded
sequence number. Snapshots are optimization aids; events remain the source of truth.

The snapshot record contains all necessary information: domain, stream_id, sequence,
timestamp, and state. This design is consistent with event persistence, where complete
records are passed rather than decomposed fields.

- Snapshot is the complete snapshot record to persist.

Returns `ok` on success, or `{warning, Reason}` if persistence fails. Returning a
warning is preferred over throwing an exception, as snapshot failures should not
crash aggregates.
""".
-callback store(Snapshot) -> ok | {warning, Reason} when
    Snapshot :: es_contract_snapshot:t(),
    Reason :: term().

-doc """
Load the latest snapshot for a stream.

This callback retrieves the most recent snapshot for the given stream, if one exists.
The snapshot enables fast state reconstruction by avoiding full event replay from
the beginning of the stream.

- StreamId is the unique identifier for the stream.

Returns `{ok, Snapshot}` if a snapshot exists, or `{error, not_found}` if no snapshot
has been saved for this stream.
""".
-callback load_latest(StreamId) -> {ok, Snapshot} | {error, not_found} when
    StreamId :: es_contract_snapshot:stream_id(),
    Snapshot :: es_contract_snapshot:t().
