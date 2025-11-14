-module(es_core_aggregate).

-include_lib("es_contract/include/es_contract.hrl").
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
    dispatch/2
]).

-export_type([
    command/0,
    aggregate_state/0,
    stream_id/0,
    state/0,
    sequence/0,
    timestamp/0
]).

-define(SEQUENCE_ZERO, 0).
-define(INACTIVITY_TIMEOUT, 5000).

-type aggregate_state() :: es_aggregate_behaviour:aggregate_state().

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
    StoreContext :: es_core_store:store_context(),
    Id :: stream_id(),
    Opts ::
        #{
            timeout => timeout(),
            sequence_zero => fun(() -> sequence()),
            sequence_next => fun((sequence()) -> sequence()),
            now_fun => fun(() -> timestamp()),
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
    StoreContext :: es_core_store:store_context(),
    Id :: stream_id()
) ->
    gen_server:start_ret().
start_link(Aggregate, StoreContext, Id) ->
    start_link(Aggregate, StoreContext, Id, #{}).

-spec dispatch(Pid, Command) -> {ok, Result} | {error, Reason} when
    Pid :: pid(),
    Command :: command(),
    Result :: term(),
    Reason :: term().
dispatch(Pid, Command) ->
    gen_server:call(Pid, Command).

-record(state, {
    aggregate :: module(),
    store :: es_core_store:store_context(),
    id :: stream_id(),
    state :: aggregate_state(),
    sequence = ?SEQUENCE_ZERO :: non_neg_integer(),
    timeout = ?INACTIVITY_TIMEOUT :: timeout(),
    sequence_zero :: fun(() -> sequence()),
    sequence_next :: fun((sequence()) -> sequence()),
    now_fun :: fun(() -> timestamp()),
    timer_ref = undefined :: reference() | undefined,
    snapshot_interval = 0 :: non_neg_integer()
}).

-opaque state() :: #state{}.

-doc """
Initializes the aggregate process.

Retrieves all events for the aggregate from the persistence layer and applies them
sequentially to rehydrate the aggregate's state.

- Aggregate is the aggregate module implementing the domain logic.
- StoreContext is a `{EventStore, SnapshotStore}` tuple used for event and snapshot persistence.
- Id is the unique identifier for the aggregate.
- Opts is a map of options including:
  - `timeout`: Inactivity timeout in milliseconds.
  - `sequence_zero`: Function to get the initial sequence number.
  - `sequence_next`: Function to get the next sequence number.
  - `now_fun`: Function to get the current timestamp.
  - `snapshot_interval`: Interval for snapshot creation.

Function returns {ok, state()} on success, and returns {stop, Reason} on failure.
""".
-spec init(
    {module(), es_core_store:store_context(), stream_id(), #{
        timeout => timeout(),
        sequence_zero => fun(() -> sequence()),
        sequence_next => fun((sequence()) -> sequence()),
        now_fun => fun(() -> timestamp()),
        snapshot_interval => non_neg_integer()
    }}
) ->
    {ok, state()}.
init({Aggregate, StoreContext, Id, Opts}) ->
    State0 = Aggregate:init(),
    SequenceZero = maps:get(sequence_zero, Opts, fun() -> ?SEQUENCE_ZERO end),
    SequenceNext = maps:get(sequence_next, Opts, fun(Sequence) -> Sequence + 1 end),

    %% Try to load the latest snapshot
    {StateFromSnapshot, SequenceFromSnapshot} =
        case es_core_store:load_latest(StoreContext, Id) of
            {ok, Snapshot} ->
                SnapshotState = es_core_store:snapshot_state(Snapshot),
                SnapshotSeq = es_core_store:snapshot_sequence(Snapshot),
                {SnapshotState, SnapshotSeq};
            {error, not_found} ->
                {State0, SequenceZero()}
        end,

    %% Replay events after the snapshot
    FoldFun =
        fun(Event, {StateAcc, _SeqAcc}) ->
            {
                Aggregate:apply_event(
                    es_core_store:payload(Event), StateAcc
                ),
                es_core_store:sequence(Event)
            }
        end,
    {State1, Sequence1} =
        es_core_store:fold(
            StoreContext,
            Id,
            FoldFun,
            {StateFromSnapshot, SequenceFromSnapshot},
            es_range:new(SequenceFromSnapshot + 1, infinity)
        ),
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
        sequence_zero = SequenceZero,
        sequence_next = SequenceNext,
        now_fun = maps:get(now_fun, Opts, fun() -> erlang:system_time(millisecond) end),
        timer_ref = TimerRef,
        snapshot_interval = SnapshotInterval
    }}.

-doc """
Handles a call to the aggregate.

- Command is the command to be processed by the aggregate.
- From is the caller's process identifier and a reference term.
- State is the current state of the aggregate.

Function returns A tuple indicating the result of the call and the new state of the aggregate.
""".
-spec handle_call(Command :: command(), From :: {pid(), term()}, State :: state()) ->
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
-spec handle_cast(Command :: command(), State :: state()) -> {noreply, state()}.
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
    Command :: command(),
    State1 :: aggregate_state(),
    Sequence1 :: sequence(),
    Result :: {State1, Sequence1},
    Reason :: term().
process_command(
    #state{
        aggregate = Aggregate,
        store = StoreContext,
        id = Id,
        state = State0,
        sequence = Sequence0,
        sequence_next = SequenceNext,
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
                PayloadEvents, {Aggregate, StoreContext, Id, Sequence0, SequenceNext, NowFun}
            ),
            {State1, Sequence1} =
                apply_events(PayloadEvents, {Aggregate, State0, Sequence0, SequenceNext}),
            {ok, {State1, Sequence1}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec apply_events(
    PayloadEvents :: [event_payload()],
    {
        Aggregate :: module(),
        State :: aggregate_state(),
        Sequence0 :: sequence(),
        SequenceNext :: fun((sequence()) -> sequence())
    }
) ->
    {State :: aggregate_state(), Sequence :: sequence()}.
apply_events(PayloadEvents, {Aggregate, State0, Sequence0, SequenceNext}) ->
    lists:foldl(
        fun(Event, {StateN, SequenceN}) ->
            StateN1 = Aggregate:apply_event(Event, StateN),
            SequenceN1 = SequenceNext(SequenceN),
            {StateN1, SequenceN1}
        end,
        {State0, Sequence0},
        PayloadEvents
    ).

-spec persist_events(
    PayloadEvents :: [event_payload()],
    {
        Aggregate :: module(),
        StoreContext :: es_core_store:store_context(),
        Id :: stream_id(),
        Sequence0 :: sequence(),
        SequenceNext :: fun((sequence()) -> sequence()),
        NowFun :: fun(() -> timestamp())
    }
) -> ok.
persist_events(PayloadEvents, {Aggregate, StoreContext, Id, Sequence0, SequenceNext, NowFun}) ->
    {Events, _} =
        lists:foldl(
            fun(PayloadEvent, {Events, SequenceN}) ->
                Now = NowFun(),
                SequenceN1 = SequenceNext(SequenceN),
                EventType = Aggregate:event_type(PayloadEvent),
                Event =
                    es_core_store:new_event(
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
    es_core_store:append(StoreContext, Id, Events).

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
    Snapshot = es_core_store:new_snapshot(Aggregate, Id, Sequence, Timestamp, AggState),
    case es_core_store:store(StoreContext, Snapshot) of
        ok ->
            ok;
        {warning, Reason} ->
            logger:warning("Snapshot save failed for ~p at seq ~p: ~p", [Id, Sequence, Reason]),
            ok
    end;
maybe_save_snapshot(_) ->
    ok.
