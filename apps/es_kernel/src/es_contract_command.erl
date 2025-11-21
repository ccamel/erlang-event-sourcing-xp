-module(es_contract_command).

-export([
    new/6,
    key/1,
    with_metadata/2,
    put_metadata/3,
    with_tags/2,
    add_tag/2,
    map_payload/2
]).

-export_type([
    domain/0,
    stream_id/0,
    sequence/0,
    type/0,
    metadata_key/0,
    metadata_value/0,
    metadata/0,
    tag/0,
    tags/0,
    payload/0,
    t/0,
    key/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-doc "Domain identifier, representing a bounded context.".
-type domain() :: atom().

-doc "Stream identifier, uniquely identifying the target aggregate stream.".
-type stream_id() :: binary().

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

The payload is self-sufficient and contains all necessary information to execute
the command, including the aggregate identifier(s) it applies to.
""".
-type payload() :: term().

-doc """
Command data structure.

A command represents an intent to change the state of an aggregate in a specific domain.
It consists of:
- `domain`: The domain this command belongs to
- `type`: The type of command to execute
- `stream_id`: Identifier of the target aggregate stream
- `sequence`: Optional sequencing information for idempotency/correlation
- `metadata`: Additional contextual information (user, timestamp, correlation ID, etc.)
- `tags`: Labels for categorization or routing
- `payload`: The actual command data (self-sufficient, includes aggregate ID(s))
""".
-type t() :: #{
    domain := domain(),
    type := type(),
    stream_id := stream_id(),
    sequence := sequence(),
    metadata := metadata(),
    tags := tags(),
    payload := payload()
}.

-type key() :: {domain(), stream_id(), sequence()}.

%%--------------------------------------------------------------------
%% Functions
%%--------------------------------------------------------------------

-spec new(domain(), type(), stream_id(), sequence(), metadata(), payload()) -> t().
new(Domain, Type, StreamId, Sequence, Metadata, Payload) ->
    #{
        domain    => Domain,
        type      => Type,
        stream_id => StreamId,
        sequence  => Sequence,
        metadata  => Metadata,
        tags      => [],
        payload   => Payload
    }.

-spec key(t()) -> key().
key(#{domain := D, stream_id := S, sequence := Seq}) ->
    {D, S, Seq}.

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
