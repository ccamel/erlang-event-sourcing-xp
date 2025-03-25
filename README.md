# erlang-event-sourcing-xp

> 🧪 Experimenting with Event Sourcing in Erlang using _pure functional_ principles, [gen_server](https://www.erlang.org/doc/apps/stdlib/gen_server.html)-based aggregates, and _pluggable_ Event Store backends.

## About

I'm a big fan of [Erlang/OTP][Erlang] and [Event Sourcing], and I strongly believe that the _Actor Model_ and _Event Sourcing_ are a natural fit. This repository is my way of exploring how these two concepts can work together in practice.

As an **experiment**, this repo won't cover every facet of event sourcing in depth, but it should provide some insights and spark ideas on the potential of this approach in [Erlang].

[Erlang]: https://www.erlang.org/
[Event Sourcing]: https://learn.microsoft.com/en-us/azure/architecture/patterns/event-sourcing

## Architecture

### Overview

This project is structured around the core principles of Event Sourcing:

- All changes are represented as immutable events.
- Aggregates handle commands and apply events to evolve their state.
- State is rehydrated by replaying historical events. Possible optimizations include snapshots and caching.

### Event store

The event store is a core component in this experiment, designed as a customizable `behaviour` that any `module` can implement to handle event storage. Its primary responsibilities include storing and retrieving events.

```erlang
% Initializes the event store
-callback start() -> {ok, initialized | already_initialized} | {error, term()}.

% Shuts down the event store.
-callback stop() -> {ok} | {error, term()}.

% Persists a list of events for a given stream.
-callback persist_events(StreamId, Events) -> ok | {error, term()}
    when StreamId :: stream_id(),
         Events :: [event()].

% Retrieves events from a stream and folds them using a provided function
-callback retrieve_and_fold_events(StreamId, Options, FoldFun, InitialAcc) -> {ok, Acc} | {error, term()}
    when StreamId :: stream_id(),
         Options :: fold_events_opts(),
         FoldFun :: fold_events_fun(),
         InitialAcc :: Acc.
```

#### Future Features

While not yet implemented, the event store could be extended to:

- Store snapshots of the aggregate’s state for efficient retrieval.
- Support event subscriptions for real-time updates.

#### Current Implementation

- [Mnesia](https://www.erlang.org/doc/apps/mnesia/mnesia.html)
- [ETS](https://www.erlang.org/doc/apps/stdlib/ets.html)

### Aggregate

The _aggregate_ is implemented as a [gen_server](https://www.erlang.org/doc/apps/stdlib/gen_server.html) that encapsulates _domain logic_ and delegates event persistence to a pluggable Event Store (e.g. [ETS](https://www.erlang.org/doc/apps/stdlib/ets.html) or [Mnesia](https://www.erlang.org/doc/apps/mnesia/mnesia.html)).

The core idea is to separate concerns between domain behavior and infrastructure. To achieve this, the system is structured into three main components:
• 🧩 **Domain Module** — a pure module that implements domain-specific logic via behaviour callbacks.
• ⚙️ **`gen_aggregate`** — the glue that bridges domain logic and infrastructure (event sourcing logic, event persistence, etc.).
• 🚦 [`gen_server`](https://www.erlang.org/doc/apps/stdlib/gen_server.html) — the OTP mechanism that provides lifecycle management and message orchestration.

The `gen_aggregate` provides:

- A [behaviour](https://www.erlang.org/doc/system/design_principles.html#behaviours) for domain-specific modules to implement.
- A generic [OTP](https://www.erlang.org/doc/system/design_principles.html) [gen_server](https://www.erlang.org/doc/apps/stdlib/gen_server.html) that:
  - Rehydrates state from events on startup.
  - Processes commands to produce events.
  - Applies events to evolve internal state.
  - Automatically passivates (shuts down) after inactivity.

The following diagram shows how the system processes a command using the event-sourced aggregate infrastructure.

```mermaid
sequenceDiagram
    actor User
    participant GenAggregate as gen_aggregate
    participant GenServer as gen_server
    participant DomainModule as AggregateModule (callback)

    User ->> GenAggregate: gen_aggregate:start_link(...)
    activate GenAggregate
    GenAggregate ->>+ GenServer: gen_server:start_link(Module, State)
    GenServer ->> GenAggregate: gen_aggregate:init/1
    deactivate GenAggregate

    User ->> GenAggregate: gen_aggregate:dispatch(Pid, Command)
    activate GenAggregate
    GenAggregate ->> GenServer: gen_server:call(Pid, Command)
    GenServer ->> GenAggregate: gen_aggregate:handle_call/3

    GenAggregate ->> DomainModule: handle_command(Command, State)
    GenAggregate ->> GenAggregate: persist_events(Store, Events)

    loop For each Event
        GenAggregate ->> DomainModule: apply_event(Event, State)
    end
    deactivate GenAggregate
```

## Build

```sh
rebar3 compile
```

## Test

```sh
rebar3 eunit
```
