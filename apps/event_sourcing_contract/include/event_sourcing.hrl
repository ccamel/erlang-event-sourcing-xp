%%% Miscellaneous types
-type tag() :: string().
-type tags() :: [tag()].
-type timestamp() :: non_neg_integer().  %% Milliseconds since epoch
-type metadata() :: #{string() => string()}.

%%% Event sourcing concepts
-type domain() :: atom().
-type stream_id() :: string() | binary().

%%% Event specification
-type event_id() :: {domain(), stream_id(), sequence()}.
-type event_type() :: atom().
-type sequence() :: non_neg_integer().
-type event_payload() :: term().

-record(event,
        {stream_id :: stream_id(),
         domain :: domain(),
         type :: event_type(),
         sequence :: sequence(),
         tags = [] :: tags(),
         timestamp :: timestamp(),
         metadata = #{} :: metadata(),
         payload :: event_payload()}).

-doc """
Represents a single persisted event in the event sourcing system.

An event is an immutable record of a domain change, belonging to a specific stream.
It includes metadata, a timestamp, and a payload with domain-specific data. This
opaque type is used internally by the store and returned by `retrieve_and_fold_events/4`.

Fields:
- `stream_id`: Stream identifier (e.g., "user-001").
- `domain` : Domain name (e.g., "user").
- `type`: Event type (e.g., "user_registered").
- `sequence`: Event sequence within the stream (e.g., 1).
- `tags`: List of strings for categorization (e.g., ["auth", "signup"]).
- `timestamp`: UTC datetime of occurrence (e.g., {{2025, 3, 16}, {12, 0, 0}}).
- `metadata`: Key-value map of additional info (e.g., #{"user_agent" => "firefox"}).
- `payload`: Domain-specific data as a tuple (e.g., `{user_registered, <<"john doe">>}`).
""".
-type event() :: #event{}.

-doc """
Represents a command sent to the aggregate.

Commands are domain-defined and passed to the aggregate.
Each aggregate defines its own command structure.
""".
-type command() :: term().

%%% Snapshot specification
-type snapshot_id() :: {domain(), stream_id()}.
-type snapshot_data() :: term().

-record(snapshot,
        {stream_id :: stream_id(),
         domain :: domain(),
         sequence :: sequence(),
         timestamp :: timestamp(),
         state :: snapshot_data()}).

-doc """
Represents a snapshot of an aggregate's state at a specific point in time.

Snapshots are used to optimize aggregate rehydration by avoiding the need to
replay all events from the beginning of a stream. Instead, the aggregate can
load the latest snapshot and replay only the events that occurred after it.

Fields:
- `stream_id`: Stream identifier (e.g., "user-001").
- `domain`: Domain name (e.g., "user").
- `sequence`: The sequence number of the last event included in this snapshot.
- `timestamp`: UTC timestamp when the snapshot was created (milliseconds since epoch).
- `state`: The serialized aggregate state at the snapshot point.
""".
-type snapshot() :: #snapshot{}.
