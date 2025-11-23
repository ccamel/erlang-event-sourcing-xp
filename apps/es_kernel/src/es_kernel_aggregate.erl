-module(es_kernel_aggregate).

-include_lib("kernel/include/logger.hrl").

-behaviour(gen_server).

-export([
    start_link/3, start_link/4,
    handle_info/2,
    init/1,
    handle_call/3,
    handle_cast/2,
    code_change/3,
    terminate/2,
    execute/2
]).

-define(SEQUENCE_ZERO, 0).
-define(INACTIVITY_TIMEOUT, 5000).

-type aggregate_state() :: es_contract_aggregate:aggregate_state().

-record(state, {
    aggregate :: module(),
    store :: es_kernel_store:store_context(),
    id :: es_contract_event:stream_id(),
    state :: aggregate_state(),
    sequence = ?SEQUENCE_ZERO :: non_neg_integer(),
    timeout = ?INACTIVITY_TIMEOUT :: timeout(),
    now_fun :: fun(() -> non_neg_integer()),
    timer_ref = undefined :: reference() | undefined,
    snapshot_interval = 0 :: non_neg_integer()
}).

-opaque state() :: #state{}.
-export_type([state/0]).

-doc """
Starts an aggregate process with a given timeout.

- Aggregate is the aggregate module implementing the behavior.
- StoreContext is a `{EventStore, SnapshotStore}` tuple.
- Id is the unique identifier for the aggregate instance.
- Timeout is the inactivity timeout in milliseconds before passivation.

Function returns `{ok, Pid}` if successful, `{error, Reason}` otherwise.
""".
-spec start_link(Aggregate, StoreContext, Id, Opts) -> gen_server:start_ret() when
    Aggregate :: module(),
    StoreContext :: es_kernel_store:store_context(),
    Id :: es_contract_event:stream_id(),
    Opts ::
        #{
            timeout => timeout(),
            now_fun => fun(() -> non_neg_integer()),
            snapshot_interval => non_neg_integer()
        }.
start_link(Aggregate, StoreContext, Id, Opts) ->
    gen_server:start_link(?MODULE, {Aggregate, StoreContext, Id, Opts}, []).

-doc """
Starts a new aggregate process.

- Aggregate is the aggregate module to start.
- StoreContext must be provided as `{EventStore, SnapshotStore}`.
- Id is the unique identifier for the aggregate instance.
""".
-spec start_link(
    Aggregate :: module(),
    StoreContext :: es_kernel_store:store_context(),
    Id :: es_contract_event:stream_id()
) ->
    gen_server:start_ret().
start_link(Aggregate, StoreContext, Id) ->
    start_link(Aggregate, StoreContext, Id, #{}).

-doc """
Executes a command on an aggregate instance.

This function sends a command to an already running aggregate process,
which will handle the command and persist resulting events.

- Pid is the process identifier of the aggregate instance.
- Command is the command to execute.

Function returns `ok` on success, or `{error, Reason}` if command execution fails.
""".
-spec execute(Pid, Command) -> ok | {error, Reason} when
    Pid :: pid(),
    Command :: es_contract_command:t(),
    Reason :: term().
execute(Pid, Command) ->
    gen_server:call(Pid, Command).
-doc """
Initializes the aggregate process.

Sets up the aggregate state by rehydrating from persistence layer and
configuring the passivation timer.

- Aggregate is the aggregate module implementing the domain logic.
- StoreContext is a `{EventStore, SnapshotStore}` tuple used for event and snapshot persistence.
- Id is the unique identifier for the aggregate.
- Opts is a map of options including:
  - `timeout`: Inactivity timeout in milliseconds.
  - `now_fun`: Function to get the current timestamp.
  - `snapshot_interval`: Interval for snapshot creation.

Function returns {ok, state()} on success, and returns {stop, Reason} on failure.
""".
-spec init(
    {module(), es_kernel_store:store_context(), es_contract_event:stream_id(), #{
        timeout => timeout(),
        now_fun => fun(() -> non_neg_integer()),
        snapshot_interval => non_neg_integer()
    }}
) ->
    {ok, state()}.
init({Aggregate, StoreContext, Id, Opts}) ->
    {State1, Sequence1} = rehydrate(Aggregate, StoreContext, Id),
    Timeout = maps:get(timeout, Opts, ?INACTIVITY_TIMEOUT),
    SnapshotInterval = maps:get(snapshot_interval, Opts, 0),
    TimerRef = install_passivation(Timeout, undefined),
    {ok, #state{
        aggregate = Aggregate,
        store = StoreContext,
        id = Id,
        state = State1,
        sequence = Sequence1,
        timeout = Timeout,
        now_fun = maps:get(now_fun, Opts, fun() -> erlang:system_time(millisecond) end),
        timer_ref = TimerRef,
        snapshot_interval = SnapshotInterval
    }}.

-doc """
Rehydrates the aggregate state from the persistence layer.

Loads the latest snapshot (if available) and replays all events after
the snapshot to rebuild the current state.

- Aggregate is the aggregate module.
- StoreContext is the storage context for events and snapshots.
- Id is the stream identifier.

Function returns {State, Sequence} tuple representing the current state and sequence number.
""".
-spec rehydrate(Aggregate, StoreContext, Id) -> {State, Sequence} when
    Aggregate :: module(),
    StoreContext :: es_kernel_store:store_context(),
    Id :: es_contract_event:stream_id(),
    State :: aggregate_state(),
    Sequence :: non_neg_integer().
rehydrate(Aggregate, StoreContext, Id) ->
    State0 = Aggregate:init(),
    {StateFromSnapshot, SequenceFromSnapshot} =
        case es_kernel_store:load_latest(StoreContext, Id) of
            {ok, Snapshot} ->
                SnapshotState = es_kernel_store:snapshot_state(Snapshot),
                SnapshotSeq = es_kernel_store:snapshot_sequence(Snapshot),
                {SnapshotState, SnapshotSeq};
            {error, not_found} ->
                {State0, ?SEQUENCE_ZERO}
        end,
    FoldFun =
        fun(Event, {StateAcc, _SeqAcc}) ->
            {
                Aggregate:apply_event(
                    es_kernel_store:payload(Event), StateAcc
                ),
                es_kernel_store:sequence(Event)
            }
        end,
    es_kernel_store:fold(
        StoreContext,
        Id,
        FoldFun,
        {StateFromSnapshot, SequenceFromSnapshot},
        es_contract_range:new(SequenceFromSnapshot + 1, infinity)
    ).

-doc """
Handles a call to the aggregate.

- Command is the command to be processed by the aggregate.
- From is the caller's process identifier and a reference term.
- State is the current state of the aggregate.

Function returns A tuple indicating the result of the call and the new state of the aggregate.
""".
-spec handle_call(Command :: es_contract_command:t(), From :: {pid(), term()}, State :: state()) ->
    {reply, ok, state()} | {reply, {error, term()}, State :: state()}.
handle_call(Command, _From, State) ->
    NewTimerRef = install_passivation(State#state.timeout, State#state.timer_ref),
    case process_command(State, Command) of
        {ok, {State1, Sequence1}} ->
            maybe_save_snapshot(State#state{state = State1, sequence = Sequence1}),
            {reply, ok, State#state{
                state = State1,
                sequence = Sequence1,
                timer_ref = NewTimerRef
            }};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

-doc """
Handles a cast message (asynchronous message) sent to the aggregate process.

- Command is the command to be processed by the aggregate.
- State is the current state of the aggregate process.

Function returns A tuple indicating no reply and the updated state of the aggregate process.
""".
-spec handle_cast(Command :: es_contract_command:t(), State :: state()) -> {noreply, state()}.
handle_cast(Command, State) ->
    NewTimerRef = install_passivation(State#state.timeout, State#state.timer_ref),
    case process_command(State, Command) of
        {ok, {State1, Sequence1}} ->
            maybe_save_snapshot(State#state{state = State1, sequence = Sequence1}),
            {noreply, State#state{
                state = State1,
                sequence = Sequence1,
                timer_ref = NewTimerRef
            }};
        {error, _} ->
            {noreply, State}
    end.

terminate(_Reason, _State) ->
    ok.

handle_info(passivate, State) ->
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-doc """
Installs a passivation mechanism for the aggregate.

- Timeout is the time in milliseconds after which the aggregate should be passivated.
- TimerRef is a reference to the timer that will trigger the passivation.
""".
-spec install_passivation(Timeout, TimerRef0) -> TimerRef1 when
    Timeout :: non_neg_integer(),
    TimerRef0 :: reference() | undefined,
    TimerRef1 :: reference().
install_passivation(Timeout, TimerRef) ->
    _ =
        case TimerRef of
            undefined ->
                ok;
            _ ->
                erlang:cancel_timer(TimerRef)
        end,
    erlang:send_after(Timeout, self(), passivate).

-doc """
Handles a command for the given aggregate.

- State is the current state of the server.
- Command is the command to be handled.

Function returns the new state and sequence of the aggregate after the command is applied.
""".
-spec process_command(State, Command) -> {ok, Result} | {error, Reason} when
    State :: state(),
    Command :: es_contract_command:t(),
    State1 :: aggregate_state(),
    Sequence1 :: es_contract_event:sequence(),
    Result :: {State1, Sequence1},
    Reason :: term().
process_command(
    #state{
        aggregate = Aggregate,
        store = StoreContext,
        id = Id,
        state = State0,
        sequence = Sequence0,
        now_fun = NowFun
    },
    Command
) ->
    CmdResult = Aggregate:handle_command(Command, State0),
    case CmdResult of
        {ok, []} ->
            {ok, {State0, Sequence0}};
        {ok, PayloadEvents} when is_list(PayloadEvents) ->
            ok = persist_events(
                PayloadEvents, {Aggregate, StoreContext, Id, Sequence0, NowFun}
            ),
            {State1, Sequence1} =
                apply_events(PayloadEvents, {Aggregate, State0, Sequence0}),
            {ok, {State1, Sequence1}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec apply_events(
    PayloadEvents :: [es_contract_event:payload()],
    {
        Aggregate :: module(),
        State :: aggregate_state(),
        Sequence0 :: es_contract_event:sequence()
    }
) ->
    {State :: aggregate_state(), Sequence :: es_contract_event:sequence()}.
apply_events(PayloadEvents, {Aggregate, State0, Sequence0}) ->
    lists:foldl(
        fun(Event, {StateN, SequenceN}) ->
            StateN1 = Aggregate:apply_event(Event, StateN),
            SequenceN1 = SequenceN + 1,
            {StateN1, SequenceN1}
        end,
        {State0, Sequence0},
        PayloadEvents
    ).

-spec persist_events(
    PayloadEvents :: [es_contract_event:payload()],
    {
        Aggregate :: module(),
        StoreContext :: es_kernel_store:store_context(),
        Id :: es_contract_event:stream_id(),
        Sequence0 :: es_contract_event:sequence(),
        NowFun :: fun(() -> non_neg_integer())
    }
) -> ok.
persist_events(PayloadEvents, {Aggregate, StoreContext, Id, Sequence0, NowFun}) ->
    {Events, _} =
        lists:foldl(
            fun(PayloadEvent, {Events, SequenceN}) ->
                Now = NowFun(),
                SequenceN1 = SequenceN + 1,
                EventType = Aggregate:event_type(PayloadEvent),
                Event =
                    es_kernel_store:new_event(
                        Id,
                        Aggregate,
                        EventType,
                        SequenceN1,
                        Now,
                        PayloadEvent
                    ),
                {[Event | Events], SequenceN1}
            end,
            {[], Sequence0},
            PayloadEvents
        ),
    lists:foreach(
        fun(Event) ->
            logger:info("Persisting Event: ~p", [Event])
        end,
        Events
    ),
    es_kernel_store:append(StoreContext, Id, Events).

-doc """
Saves a snapshot if the snapshot interval is configured and the current
sequence is a multiple of the interval.

- State is the current aggregate state record.
""".
-spec maybe_save_snapshot(State) -> ok when State :: state().
maybe_save_snapshot(#state{snapshot_interval = 0}) ->
    ok;
maybe_save_snapshot(
    #state{
        snapshot_interval = Interval,
        sequence = Sequence,
        store = StoreContext,
        aggregate = Aggregate,
        id = Id,
        state = AggState,
        now_fun = NowFun
    }
) when Sequence rem Interval =:= 0 ->
    Timestamp = NowFun(),
    logger:info("Saving snapshot for ~p at sequence ~p", [Id, Sequence]),
    Snapshot = es_kernel_store:new_snapshot(Aggregate, Id, Sequence, Timestamp, AggState),
    case es_kernel_store:store(StoreContext, Snapshot) of
        ok ->
            ok;
        {warning, Reason} ->
            logger:warning("Snapshot save failed for ~p at seq ~p: ~p", [Id, Sequence, Reason]),
            ok
    end;
maybe_save_snapshot(_) ->
    ok.
