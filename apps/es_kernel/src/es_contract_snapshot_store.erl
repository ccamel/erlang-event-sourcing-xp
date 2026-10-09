-module(es_contract_snapshot_store).
-moduledoc """
Behaviour for **snapshot store backends**.

A snapshot store backend handles persistence of aggregate snapshots — condensed
representations of the state after applying a set of events. It defines the
functional capabilities for snapshot operations, independent of lifecycle concerns.

Callbacks:
- `store/1` — persist a snapshot of the aggregate state
- `load_latest/1` — fetch the most recent snapshot for a given stream

Design principles:
- Snapshots are **optional optimizations**; events remain the source of truth.
- Backends should prefer returning `{warning, Reason}` instead of crashing when persistence fails.
- Each stream typically holds only its latest snapshot, though implementations
  may store historical versions if needed.

Common implementations include key–value stores, databases, or object storage
systems (e.g., S3).

Note: Backend implementations may provide `start/0` and `stop/0` functions for
lifecycle management, but these are not part of this behaviour contract.
""".

-doc """
Store a snapshot for a stream.

Persist the aggregate state after applying all events through the snapshot's
sequence. Snapshots are optional optimizations; events remain the source of truth.

`Snapshot` is a map containing `aggregate_type`, `stream_id`, `sequence`,
`metadata`, and `state`. The timestamp is stored in `metadata.timestamp`.

Returns `ok` on success, or `{warning, Reason}` if persistence fails. Snapshot
failures should not crash aggregates.
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
