-module(event_sourcing_core_snapshot_store).
-moduledoc "Behaviour for **snapshot store backends**.\n"
           "\n"
           "A snapshot store backend handles persistence of aggregate snapshots — condensed\n"
           "representations of the state after applying a set of events.\n"
           "\n"
           "Callbacks:\n"
           "- `start/0`, `stop/0` — manage backend initialization and shutdown\n"
           "- `save_snapshot/1` — persist a snapshot of the aggregate state\n"
           "- `retrieve_latest_snapshot/1` — fetch the most recent snapshot for a given stream\n"
           "\n"
           "Design principles:\n"
           "- Snapshots are **optional optimizations**; events remain the source of truth.\n"
           "- Backends should prefer returning `{warning, Reason}` instead of crashing when persistence fails.\n"
           "- Each stream typically holds only its latest snapshot, though implementations\n"
           "  may store historical versions if needed.\n"
           "\n"
           "Common implementations include key–value stores, databases, or object storage\n"
           "systems (e.g., S3).".

-include_lib("event_sourcing_core/include/event_sourcing_core.hrl").

-doc "Save a snapshot for a stream.\n"
     "\n"
     "This callback saves a snapshot of the aggregate state at a specific point in time.\n"
     "The snapshot represents the aggregate state after all events up to and including\n"
     "the given sequence number have been applied.\n"
     "\n"
     "The snapshot record already contains all necessary information including domain,\n"
     "stream_id, sequence, timestamp, and state. This is consistent with how events\n"
     "are handled - they are passed as complete records rather than decomposed fields.\n"
     "\n"
     "- Snapshot is the complete snapshot record to persist.\n"
     "\n"
     "Returns `ok` on success, or `{warning, Reason}` if persistence fails. Returning a\n"
     "warning is preferred over throwing an exception, as snapshot failures should not\n"
     "crash aggregates (events are the source of truth).".
-callback save_snapshot(Snapshot) -> ok | {warning, Reason} when
    Snapshot :: snapshot(),
    Reason :: term().

-doc "Retrieve the latest snapshot for a stream.\n"
     "\n"
     "This callback retrieves the most recent snapshot for the given stream, if one exists.\n"
     "The snapshot can be used to restore aggregate state without replaying all events.\n"
     "\n"
     "- StreamId is the unique identifier for the stream.\n"
     "\n"
     "Returns `{ok, Snapshot}` if a snapshot exists, or `{error, not_found}` if no snapshot\n"
     "has been saved for this stream.".
-callback retrieve_latest_snapshot(StreamId) -> {ok, Snapshot} | {error, not_found} when
    StreamId :: stream_id(),
    Snapshot :: snapshot().
