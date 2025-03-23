# erlang-event-sourcing-xp

> 🧪 Experimenting with Event Sourcing in Erlang

## About

I'm a big fan of [Erlang/OTP][Erlang] and [Event Sourcing], and I strongly believe that the _Actor Model_ and _Event Sourcing_ are a natural fit. This repository is my way of exploring how these two concepts can work together in practice.

As an **experiment**, this repo won't cover every facet of event sourcing in depth, but it should provide some insights and spark ideas on the potential of this approach in [Erlang].

[Erlang]: https://www.erlang.org/
[Event Sourcing]: https://learn.microsoft.com/en-us/azure/architecture/patterns/event-sourcing

## Architecture

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

##### Mnesia Event Store

The Mnesia event store uses [Mnesia](https://www.erlang.org/doc/apps/mnesia/mnesia.html) as its underlying storage mechanism. Events are stored as records with the following structure:

```erlang
{ key :: id(),
  stream_id :: stream_id(),
  sequence :: sequence(),
  event :: event()}.
```

## Build

```sh
rebar3 compile
```

## Test

```sh
rebar3 eunit
```
