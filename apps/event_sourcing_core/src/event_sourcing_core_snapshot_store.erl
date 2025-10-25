-module(event_sourcing_core_snapshot_store).
-moduledoc """
Behaviour for **snapshot store backends**.

A snapshot store backend handles persistence of aggregate snapshots — condensed
representations of the state after applying a set of events.

Callbacks:
- `start/0`, `stop/0` — manage backend initialization and shutdown
- `save_snapshot/1` — persist a snapshot of the aggregate state
- `retrieve_latest_snapshot/1` — fetch the most recent snapshot for a given stream

Design principles:
- Snapshots are **optional optimizations**; events remain the source of truth.
- Backends should prefer returning `{warning, Reason}` instead of crashing when persistence fails.
- Each stream typically holds only its latest snapshot, though implementations
  may store historical versions if needed.

Common implementations include key–value stores, databases, or object storage
systems (e.g., S3).
""".

-include_lib("event_sourcing_core/include/event_sourcing_core.hrl").

-doc """
Save a snapshot for a stream.

This callback saves a snapshot of the aggregate state at a specific point in time.
The snapshot represents the aggregate state after all events up to and including
the given sequence number have been applied.

The snapshot record already contains all necessary information including domain,
stream_id, sequence, timestamp, and state. This is consistent with how events
are handled - they are passed as complete records rather than decomposed fields.

- Snapshot is the complete snapshot record to persist.

Returns `ok` on success, or `{warning, Reason}` if persistence fails. Returning a
warning is preferred over throwing an exception, as snapshot failures should not
crash aggregates (events are the source of truth).
""".
-callback save_snapshot(Snapshot) -> ok | {warning, Reason} when
    Snapshot :: snapshot(),
    Reason :: term().

-doc """
Retrieve the latest snapshot for a stream.

This callback retrieves the most recent snapshot for the given stream, if one exists.
The snapshot can be used to restore aggregate state without replaying all events.

- StreamId is the unique identifier for the stream.

Returns `{ok, Snapshot}` if a snapshot exists, or `{error, not_found}` if no snapshot
has been saved for this stream.
""".
-callback retrieve_latest_snapshot(StreamId) -> {ok, Snapshot} | {error, not_found} when
    StreamId :: stream_id(),
    Snapshot :: snapshot().
