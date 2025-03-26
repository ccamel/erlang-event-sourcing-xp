%% @doc
%% Defines the aggregate behaviour for event-sourced domain modules.
%%
%% Modules implementing this behaviour encapsulate the pure domain logic
%% for handling commands and applying events. This behaviour is intended
%% to be used by `gen_aggregate`-based processes for executing commands,
%% rehydrating state from events, and projecting changes to domain state.
%%
%% Implementers are responsible for:
%% - Initializing domain state (`init/0`)
%% - Handling commands and returning domain events (`handle_command/2`)
%% - Applying events to evolve state (`apply_event/2`)
%% - Identifying the event type for a payload (`event_type/1`)
-module(event_sourcing_core_aggregate_beh).

-include_lib("event_sourcing_core.hrl").

-export_type([aggregate_state/0]).

-type aggregate_state() :: term().

%% @doc
%% Initialize the aggregate's state.
%%
%% This is called once when the aggregate process is started and before
%% any events have been applied.
%%
%% @return The initial aggregate state.
-callback init() -> aggregate_state().
%% @doc
%% Determine the event type for a given payload.
%%
%% This is used internally to construct full event records
%% during command handling. The returned type is stored in the event store.
%%
%% @param Payload The raw event payload.
%% @return An atom representing the event type (e.g., `user_registered`).
-callback event_type(event_payload()) -> atom().
%% @doc
%% Handle a domain command.
%%
%% This function is responsible for validating and transforming a command
%% into one or more domain events. It receives the current state of the
%% aggregate and returns either:
%% - `{ok, [event_payload()]}` — A list of events to persist and apply.
%% - `{error, Reason}` — A reason for rejecting the command.
%%
%% This function should be pure and side-effect free.
%%
%% @param Command The incoming domain command.
%% @param State   The current aggregate state.
-callback handle_command(Command, State) -> {ok, [event_payload()]} | {error, term()}
    when Command :: command(),
         State :: aggregate_state().
%% @doc
%% Apply a domain event to the aggregate state.
%%
%% This function must be deterministic and pure — given the same event and state,
%% it should always return the same result. It is used both during rehydration
%% (when replaying past events) and after handling a new command.
%%
%% @param Event   The domain event to apply.
%% @param State0  The current aggregate state.
%% @return        The updated aggregate state.
-callback apply_event(Event, State0) -> State1
    when Event :: event_payload(),
         State0 :: aggregate_state(),
         State1 :: aggregate_state().
