-module(es_contract_aggregate).
-moduledoc """
Defines the aggregate behaviour for event-sourced domain modules.

Modules implementing this behaviour provide the pure domain logic consumed by
`es_kernel_aggregate` to handle commands and rebuild state from events.

Implementers are responsible for:

- Initializing domain state (`init/0`)
- Handling commands and returning domain events (`handle_command/2`)
- Applying events to evolve state (`apply_event/2`)
- Identifying the event type for a payload (`event_type/1`)
""".

-export_type([aggregate_state/0]).

-type aggregate_state() :: term().

-doc """
Return the initial domain state.

Called before replay during each rehydration, including startup and conflict
recovery.
""".
-callback init() -> aggregate_state().

-doc """
Return the canonical event type identifier for a domain event payload.
""".
-callback event_type(Event) -> Type when
    Event :: es_contract_event:payload(),
    Type :: es_contract_event:type().

-doc """
Validate a command against the current aggregate state and return:

- `{ok, Payloads}` — Zero or more domain event payloads to persist and apply.
- `{error, Reason}` — A reason for rejecting the command.

This function should be pure and side-effect free.

- Command is the incoming domain command.
- State is the current aggregate state.
""".
-callback handle_command(Command, State) ->
    {ok, [es_contract_event:payload()]} | {error, term()}
when
    Command :: es_contract_command:t(),
    State :: aggregate_state().
-doc """
Return the state obtained by applying a domain event.

This function must be deterministic and pure — given the same event and state,
it should always return the same result. It is used both during rehydration
(when replaying events) and after a successful append.

- Event is the domain event payload.
- State0 is the current aggregate state.
""".
-callback apply_event(Event, State0) -> State1 when
    Event :: es_contract_event:payload(),
    State0 :: aggregate_state(),
    State1 :: aggregate_state().
