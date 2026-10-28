-module(es_contract_domain).
-moduledoc """
Defines the runtime boundary for event-sourced domains outside the native path.

Register `#{runtime => RuntimeModule, ...}` with `es_kernel_registry`. The runtime
module implements these callbacks; the complete descriptor is their first
argument. Only `runtime` belongs to the kernel. All other descriptor fields,
validation, guest protocols, execution resources, deadlines and cleanup belong
to the runtime. Descriptors are immutable startup configuration, not mutable
runtime state. Native `#{runtime => erlang, module => DomainModule}` descriptors
continue to use `es_contract_aggregate` directly.

The kernel owns persistence, aggregate processes, replay and snapshots. Runtime
callbacks must not persist events or mutate aggregate state outside their return
values. Command decisions should be pure; initialization and event application
must be deterministic and side-effect free. State must remain reconstructible
from the same initial state and ordered events, including after a snapshot.

`handle_command/3` returns `{error, Reason}` for rejection or recoverable execution
failure: the kernel returns that error without appending events or changing state.
`{ok, []}` is a successful no-op. Runtime implementations validate their own guest
results and event payloads before returning them. Initialization, event application
and event typing have no error-return variant: failures must raise rather than
become domain state or silently skip an event. Exceptions propagate to the
aggregate's OTP lifecycle; the dispatch layer does not catch or translate them.
""".

-doc """
Return initial state before every rehydration, even when a snapshot is available.
The same descriptor must always produce the same initial state.
""".
-callback init(Domain) -> es_contract_aggregate:aggregate_state() when
    Domain :: es_kernel_registry:domain().

-doc """
Decide a command against current state without changing that state.
Return zero or more event payloads to persist and apply, or reject with a reason.
""".
-callback handle_command(Domain, Command, State) ->
    {ok, [es_contract_event:payload()]} | {error, term()}
when
    Domain :: es_kernel_registry:domain(),
    Command :: es_contract_command:t(),
    State :: es_contract_aggregate:aggregate_state().

-doc """
Apply one event deterministically, both after successful append and during replay.
Snapshot state and replayed state must be interchangeable inputs.
""".
-callback apply_event(Domain, Event, State0) -> State1 when
    Domain :: es_kernel_registry:domain(),
    Event :: es_contract_event:payload(),
    State0 :: es_contract_aggregate:aggregate_state(),
    State1 :: es_contract_aggregate:aggregate_state().

-doc "Return the canonical event type for a payload before persistence.".
-callback event_type(Domain, Event) -> es_contract_event:type() when
    Domain :: es_kernel_registry:domain(),
    Event :: es_contract_event:payload().
