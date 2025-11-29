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
    aggregate_type :: es_contract_event:aggregate_type(),
    aggregate_module :: es_kernel_registry:aggregate_module(),
    store :: es_kernel_store:store_context(),
    aggregate_id :: es_contract_command:aggregate_id(),
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
Starts an aggregate process for a given aggregate type and aggregate ID.

- AggregateType is the conceptual aggregate type (e.g., bank_account).
- AggId is the aggregate identifier.
- StoreContext is the `{EventStore, SnapshotStore}` context.
- Opts controls inactivity timeout, time source, and snapshot interval.

The aggregate type will be resolved to the implementing module in init/1.
""".
-spec start_link(AggregateType, AggId, StoreContext, Opts) -> gen_server:start_ret() when
    AggregateType :: es_contract_event:aggregate_type(),
    AggId :: es_contract_command:aggregate_id(),
    StoreContext :: es_kernel_store:store_context(),
    Opts ::
        #{
            timeout => timeout(),
            now_fun => fun(() -> non_neg_integer()),
            snapshot_interval => non_neg_integer()
        }.
start_link(AggregateType, AggId, StoreContext, Opts) ->
    gen_server:start_link(?MODULE, {AggregateType, AggId, StoreContext, Opts}, []).

-doc """
Starts an aggregate process with default options.
""".
-spec start_link(
    AggregateType :: es_contract_event:aggregate_type(),
    AggId :: es_contract_command:aggregate_id(),
    StoreContext :: es_kernel_store:store_context()
) ->
    gen_server:start_ret().
start_link(AggregateType, AggId, StoreContext) ->
    start_link(AggregateType, AggId, StoreContext, #{}).

-doc """
Executes a command on an aggregate process.

Sends a command to a running aggregate and waits for the result. Returns
`ok` if the command was handled successfully, or `{error, Reason}` if
it failed.
""".
-spec execute(Pid, Command) -> ok | {error, Reason} when
    Pid :: pid(),
    Command :: es_contract_command:t(),
    Reason :: term().
execute(Pid, Command) ->
    gen_server:call(Pid, Command).
-doc """
Initializes the aggregate process.

Rehydrates the aggregate state from the store and installs the
passivation timer. Resolves the aggregate_type to its implementing module.
Options control inactivity timeout, time source, and snapshot interval.
""".
-spec init(
    {AggregateType, AggregateId, StoreContext, Opts}
) -> {ok, state()} when
    AggregateType :: es_contract_event:aggregate_type(),
    AggregateId :: es_contract_command:aggregate_id(),
    StoreContext :: es_kernel_store:store_context(),
    Opts :: #{
        timeout => timeout(),
        now_fun => fun(() -> non_neg_integer()),
        snapshot_interval => non_neg_integer()
    }.
init({AggregateType, AggId, StoreContext, Opts}) ->
    AggregateModule =
        case es_kernel_registry:lookup_module(AggregateType) of
            {ok, Module} ->
                Module;
            {error, not_found} ->
                %% Fallback: assume aggregate_type is the module name
                AggregateType
        end,

    StreamId = {AggregateType, AggId},
    {State1, Sequence1} = rehydrate(AggregateModule, StoreContext, StreamId),
    Timeout = maps:get(timeout, Opts, ?INACTIVITY_TIMEOUT),
    SnapshotInterval = maps:get(snapshot_interval, Opts, 0),
    TimerRef = install_passivation(Timeout, undefined),
    {ok, #state{
        aggregate_type = AggregateType,
        aggregate_module = AggregateModule,
        store = StoreContext,
        aggregate_id = AggId,
        state = State1,
        sequence = Sequence1,
        timeout = Timeout,
        now_fun = maps:get(now_fun, Opts, fun() -> erlang:system_time(millisecond) end),
        timer_ref = TimerRef,
        snapshot_interval = SnapshotInterval
    }}.

-doc """
Rehydrates the aggregate state from the persistence layer.

Loads the latest snapshot if available, then replays subsequent events
to rebuild the current state. Returns `{State, Sequence}` where
`State` is the aggregate state and `Sequence` the last applied event
sequence.
""".
-spec rehydrate(AggregateModule, StoreContext, StreamId) -> {State, Sequence} when
    AggregateModule :: es_kernel_registry:aggregate_module(),
    StoreContext :: es_kernel_store:store_context(),
    StreamId :: es_contract_event:stream_id(),
    State :: aggregate_state(),
    Sequence :: non_neg_integer().
rehydrate(AggregateModule, StoreContext, StreamId) ->
    State0 = AggregateModule:init(),
    {StateFromSnapshot, SequenceFromSnapshot} =
        case es_kernel_store:load_latest(StoreContext, StreamId) of
            {ok, #{state := SnapshotState, sequence := SnapshotSeq}} ->
                {SnapshotState, SnapshotSeq};
            {error, not_found} ->
                {State0, ?SEQUENCE_ZERO}
        end,
    FoldFun =
        fun(#{payload := Payload, sequence := Seq}, {StateAcc, _SeqAcc}) ->
            {
                AggregateModule:apply_event(Payload, StateAcc),
                Seq
            }
        end,
    es_kernel_store:fold(
        StoreContext,
        StreamId,
        FoldFun,
        {StateFromSnapshot, SequenceFromSnapshot},
        es_contract_range:new(SequenceFromSnapshot + 1, infinity)
    ).

-doc """
Handles synchronous commands sent to the aggregate.

Processes the command, updates state and sequence if needed, and
returns `ok` or `{error, Reason}` to the caller.
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
Handles asynchronous commands sent to the aggregate.

Processes the command and updates state and sequence if needed without
replying to the caller.
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
Installs or refreshes the passivation timer for the aggregate.

- Timeout is the inactivity delay before passivation in milliseconds.
- TimerRef is the current timer reference, if any.
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
Handles a command against the current aggregate state.

Delegates to the aggregate module to decide how to handle the command,
persists any resulting events, applies them to the state, and returns
either `{ok, {State, Sequence}}` or `{error, Reason}`.
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
        aggregate_type = AggregateType,
        aggregate_module = AggregateModule,
        store = StoreContext,
        aggregate_id = AggId,
        state = State0,
        sequence = Sequence0,
        now_fun = NowFun
    },
    Command
) ->
    StreamId = {AggregateType, AggId},
    CmdResult = AggregateModule:handle_command(Command, State0),
    case CmdResult of
        {ok, []} ->
            {ok, {State0, Sequence0}};
        {ok, PayloadEvents} when is_list(PayloadEvents) ->
            ok = persist_events(
                PayloadEvents, {AggregateModule, StoreContext, StreamId, Sequence0, NowFun}
            ),
            {State1, Sequence1} =
                apply_events(PayloadEvents, {AggregateModule, State0, Sequence0}),
            {ok, {State1, Sequence1}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec apply_events(
    PayloadEvents :: [es_contract_event:payload()],
    {
        AggregateModule :: es_kernel_registry:aggregate_module(),
        State :: aggregate_state(),
        Sequence0 :: es_contract_event:sequence()
    }
) ->
    {State :: aggregate_state(), Sequence :: es_contract_event:sequence()}.
apply_events(PayloadEvents, {AggregateModule, State0, Sequence0}) ->
    lists:foldl(
        fun(Event, {StateN, SequenceN}) ->
            StateN1 = AggregateModule:apply_event(Event, StateN),
            SequenceN1 = SequenceN + 1,
            {StateN1, SequenceN1}
        end,
        {State0, Sequence0},
        PayloadEvents
    ).

-spec persist_events(
    PayloadEvents :: [es_contract_event:payload()],
    {
        AggregateModule :: es_kernel_registry:aggregate_module(),
        StoreContext :: es_kernel_store:store_context(),
        StreamId :: es_contract_event:stream_id(),
        Sequence0 :: es_contract_event:sequence(),
        NowFun :: fun(() -> non_neg_integer())
    }
) -> ok.
persist_events(PayloadEvents, {AggregateModule, StoreContext, StreamId, Sequence0, NowFun}) ->
    %% Extract aggregate_type from StreamId (which is {aggregate_type, aggregate_id})
    {AggregateType, _AggregateId} = StreamId,
    {Events, _} =
        lists:foldl(
            fun(PayloadEvent, {Events, SequenceN}) ->
                Now = NowFun(),
                SequenceN1 = SequenceN + 1,
                EventType = AggregateModule:event_type(PayloadEvent),
                Event =
                    es_kernel_store:new_event(
                        StreamId,
                        AggregateType,
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
    es_kernel_store:append(StoreContext, StreamId, Events).

-doc """
Saves a snapshot when a snapshot interval is configured and the current
sequence is a multiple of that interval.

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
        aggregate_type = AggregateType,
        aggregate_id = AggId,
        state = AggState,
        now_fun = NowFun
    }
) when Sequence rem Interval =:= 0 ->
    StreamId = {AggregateType, AggId},
    Timestamp = NowFun(),
    logger:info("Saving snapshot for ~p at sequence ~p", [StreamId, Sequence]),
    Snapshot = es_kernel_store:new_snapshot(AggregateType, StreamId, Sequence, Timestamp, AggState),
    case es_kernel_store:store(StoreContext, Snapshot) of
        ok ->
            ok;
        {warning, Reason} ->
            logger:warning(
                "Snapshot save failed for ~p at seq ~p: ~p", [StreamId, Sequence, Reason]
            ),
            ok
    end;
maybe_save_snapshot(_) ->
    ok.
