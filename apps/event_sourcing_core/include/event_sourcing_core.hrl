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
