-module(es_contract_command).

-export([
    new/6,
    target/1,
    with_metadata/2,
    put_metadata/3,
    with_tags/2,
    add_tag/2,
    map_payload/2
]).

-export_type([
    aggregate_type/0,
    aggregate_id/0,
    sequence/0,
    type/0,
    metadata_key/0,
    metadata_value/0,
    metadata/0,
    tag/0,
    tags/0,
    payload/0,
    t/0,
    target/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-doc "Aggregate type identifier, specifying which kind of aggregate this command targets.".
-type aggregate_type() :: atom().

-doc """
Aggregate identifier, uniquely identifying an aggregate instance.

Can be any term (UUID, binary, integer, etc.).
""".
-type aggregate_id() :: term().

-doc "Sequence of the command when batching operations (optional semantic).".
-type sequence() :: non_neg_integer().

-doc "Type identifier for the command.".
-type type() :: atom() | binary().

-doc "Metadata map containing contextual information about the command.".
-type metadata_key() :: atom() | binary().
-type metadata_value() :: term().
-type metadata() :: #{metadata_key() => metadata_value()}.

-doc "Tag for categorizing commands.".
-type tag() :: binary().

-doc "List of tags associated with a command.".
-type tags() :: [tag()].

-doc """
Command payload containing the command-specific data.
""".
-type payload() :: term().

-doc """
Command data structure.

A command represents an intent to change the state of an aggregate of a specific type.
It consists of:
- `aggregate_type`: The aggregate type this command targets
- `type`: The type of command to execute
- `aggregate_id`: Identifier of the target aggregate instance
- `sequence`: Optional sequencing information for idempotency/correlation
- `metadata`: Additional contextual information (user, timestamp, correlation ID, etc.)
- `tags`: Labels for categorization or routing
- `payload`: The actual command data
""".
-type t() :: #{
    aggregate_type := aggregate_type(),
    type := type(),
    aggregate_id := aggregate_id(),
    sequence := sequence(),
    metadata := metadata(),
    tags := tags(),
    payload := payload()
}.

-doc """
Command target identifier.

The target is a tuple of the AggregateType and the AggregateId that identifies
which aggregate this command is addressed to.
""".
-type target() :: {aggregate_type(), aggregate_id()}.

%%--------------------------------------------------------------------
%% Functions
%%--------------------------------------------------------------------

-spec new(aggregate_type(), type(), aggregate_id(), sequence(), metadata(), payload()) -> t().
new(AggregateType, Type, AggregateId, Sequence, Metadata, Payload) ->
    #{
        aggregate_type => AggregateType,
        type => Type,
        aggregate_id => AggregateId,
        sequence => Sequence,
        metadata => Metadata,
        tags => [],
        payload => Payload
    }.

-spec target(t()) -> target().
target(#{aggregate_type := AggType, aggregate_id := AggId}) ->
    {AggType, AggId}.

-spec with_metadata(metadata(), t()) -> t().
with_metadata(Meta, Command) when is_map(Command) ->
    Command#{metadata := Meta}.

-spec put_metadata(metadata_key(), metadata_value(), t()) -> t().
put_metadata(Key, Value, Command) when is_map(Command) ->
    Meta = maps:get(metadata, Command),
    Command#{metadata := Meta#{Key => Value}}.

-spec with_tags(tags(), t()) -> t().
with_tags(Tags, Command) when is_map(Command) ->
    Command#{tags := Tags}.

-spec add_tag(tag(), t()) -> t().
add_tag(Tag, Command) when is_map(Command) ->
    Tags = maps:get(tags, Command),
    Command#{tags := [Tag | Tags]}.

-spec map_payload(fun((payload()) -> payload()), t()) -> t().
map_payload(Fun, Command) when is_map(Command) ->
    Payload = maps:get(payload, Command),
    Command#{payload := Fun(Payload)}.
