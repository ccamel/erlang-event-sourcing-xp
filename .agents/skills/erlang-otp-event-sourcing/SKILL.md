---
name: erlang-otp-event-sourcing
description: Implements and reviews Erlang/OTP event-sourced aggregates, process APIs, supervision trees, event replay, and pluggable event storage. Use when changing Erlang code that owns domain state or event histories. Do not use for generic Erlang utilities, non-event-sourced applications, or infrastructure unrelated to aggregate behavior.
---

# Erlang/OTP Event Sourcing

1. Inspect the repository's existing aggregate, storage, supervision, test, and documentation conventions before editing. Reuse the established interfaces and persistence abstraction.

2. Define the change at the domain boundary before implementation.
   - Express each business action as a message in the process's explicit public API.
   - Identify the domain event produced by every accepted state transition.
   - Define replay behavior: initialization and each event application must derive the same aggregate state.
   - If the requested behavior leaves a material domain rule, event schema, message protocol, supervision strategy, or storage contract unspecified, inspect existing precedent first; ask for clarification only when no precedent resolves it.

3. Implement OTP processes so state ownership and failure handling remain explicit.
   - Keep mutable aggregate state inside the process loop only.
   - Supervise processes through the existing supervision tree; do not introduce ad-hoc, unsupervised processes.
   - Keep public message interfaces documented at the module boundary.
   - Do not persist or mutate aggregate state outside the process loop without emitting the corresponding event.
   - Do not add global ETS tables, `persistent_term`, or external caches unless they belong to the existing storage-backend abstraction.

4. Preserve event-sourcing invariants.
   - Produce domain events for business actions; do not directly mutate derived state.
   - Rebuild aggregate state by folding or replaying event history.
   - Keep storage backends interchangeable by using the repository's storage abstraction rather than backend-specific APIs.
   - Ensure every aggregate or entity process can be reconstructed from its event history.

5. Update focused tests for observable behavior, including accepted and rejected commands, emitted events, replayed state, and process isolation where the change affects them. Keep tests deterministic and isolated; use the project's in-memory or mock backend when appropriate.

6. Update documentation only when public behavior, process APIs, supervision, configuration, or architecture changes. Keep examples and diagrams aligned with the implementation.

7. Verify with the project commands supported by the checkout. Run the narrowest relevant checks first, then run formatting, linting, and the full test suite when available:

```bash
rebar3 fmt --check
rebar3 lint
rebar3 eunit
```

If `rebar3 fmt --check` reports formatting changes, run `rebar3 fmt` and repeat the check. Do not commit unless explicitly requested.
