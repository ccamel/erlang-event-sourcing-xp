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
    domain :: es_kernel_registry:domain(),
    store :: es_kernel_store:store_context(),
    aggregate_id :: es_contract_command:aggregate_id(),
    state :: aggregate_state(),
    sequence = ?SEQUENCE_ZERO :: non_neg_integer(),
    timeout = ?INACTIVITY_TIMEOUT :: timeout(),
    now_fun :: fun(() -> non_neg_integer()),
    timer_ref = undefined :: reference() | undefined,
    snapshot_interval = 0 :: non_neg_integer(),
    command_ids = #{} :: #{es_contract_command:id() => true}
}).

-opaque state() :: #state{}.
-export_type([state/0]).

-doc """
Starts an aggregate process for a given aggregate type and aggregate ID.

- AggregateType is the conceptual aggregate type (e.g., bank_account).
- AggId is the aggregate identifier.
- StoreContext is the `{EventStore, SnapshotStore}` context.
- Opts controls inactivity timeout, time source, and snapshot interval.

The aggregate type is resolved to its registered domain implementation in `init/1`.
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
An already committed command ID returns `ok` without creating new events.
On an unrelated version conflict, the aggregate reloads committed events and
returns the conflict without retrying the command.

The call waits for the aggregate reply; runtimes must bound external execution.
""".
-spec execute(Pid, Command) -> ok | {error, Reason} when
    Pid :: pid(),
    Command :: es_contract_command:t(),
    Reason :: term().
execute(Pid, Command) ->
    gen_server:call(Pid, Command, infinity).
-doc """
Initializes the aggregate process.

Rehydrates the aggregate state from the store and installs the
passivation timer. Resolves the aggregate type to its domain implementation.
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
    Domain =
        case es_kernel_registry:lookup(AggregateType) of
            {ok, RegisteredDomain} ->
                RegisteredDomain;
            {error, not_found} ->
                logger:warning(
                    "No registry entry for aggregate_type ~p, "
                    "falling back to an Erlang module with the same name",
                    [AggregateType]
                ),
                #{runtime => erlang, module => AggregateType}
        end,

    {DomainState, Sequence} = load_state(Domain, StoreContext, {AggregateType, AggId}),
    Timeout = maps:get(timeout, Opts, ?INACTIVITY_TIMEOUT),
    SnapshotInterval = maps:get(snapshot_interval, Opts, 0),
    State = replay(
        #state{
            aggregate_type = AggregateType,
            domain = Domain,
            store = StoreContext,
            aggregate_id = AggId,
            state = DomainState,
            sequence = Sequence,
            timeout = Timeout,
            now_fun = maps:get(now_fun, Opts, fun() -> erlang:system_time(millisecond) end),
            snapshot_interval = SnapshotInterval
        },
        1
    ),
    {ok, State#state{timer_ref = install_passivation(Timeout, undefined)}}.

-doc "Load the starting domain state and its sequence before replay.".
-spec load_state(Domain, StoreContext, StreamId) -> {State, Sequence} when
    Domain :: es_kernel_registry:domain(),
    StoreContext :: es_kernel_store:store_context(),
    StreamId :: es_contract_event:stream_id(),
    State :: aggregate_state(),
    Sequence :: non_neg_integer().
load_state(Domain, StoreContext, StreamId) ->
    State0 = es_kernel_domain:init(Domain),
    case es_kernel_store:load_latest(StoreContext, StreamId) of
        {ok, #{state := SnapshotState, sequence := SnapshotSeq}} ->
            {SnapshotState, SnapshotSeq};
        {error, not_found} ->
            {State0, ?SEQUENCE_ZERO}
    end.

-spec replay(state(), pos_integer()) -> state().
replay(
    #state{
        domain = Domain,
        store = Store,
        aggregate_type = Type,
        aggregate_id = Id,
        state = DomainState,
        sequence = Sequence,
        command_ids = CommandIds
    } = State,
    From
) ->
    Fold = fun(#{payload := Payload} = Event, Seq, {Acc, LastSeq, Seen}) ->
        Ids = remember_command(Event, Seen),
        case Seq > Sequence of
            true -> {es_kernel_domain:apply_event(Domain, Payload, Acc), Seq, Ids};
            false -> {Acc, LastSeq, Ids}
        end
    end,
    case
        es_kernel_store:fold(
            Store,
            {Type, Id},
            Fold,
            {DomainState, Sequence, CommandIds},
            es_contract_range:new(From, infinity)
        )
    of
        {ok, {NewState, NewSequence, NewIds}} ->
            State#state{state = NewState, sequence = NewSequence, command_ids = NewIds};
        {error, Reason} ->
            erlang:error(Reason)
    end.

-spec remember_command(es_contract_event:t(), Ids) -> Ids when
    Ids :: #{es_contract_command:id() => true}.
remember_command(#{metadata := #{command_id := <<_:128>> = Id}}, Seen) ->
    Seen#{Id => true};
remember_command(_Event, Seen) ->
    Seen.

-doc """
Handles synchronous commands sent to the aggregate.

Processes the command, updates state and sequence if needed, and
returns `ok` or `{error, Reason}` to the caller.
""".
-spec handle_call(Command :: es_contract_command:t(), From :: {pid(), term()}, State :: state()) ->
    {reply, ok, state()} | {reply, {error, term()}, State :: state()}.
handle_call(Command, _From, State) ->
    {Result, NewState} = dispatch_command(Command, State),
    {reply, Result, NewState}.

-doc """
Handles asynchronous commands sent to the aggregate.

Processes the command and updates state and sequence if needed without
replying to the caller.
""".
-spec handle_cast(Command :: es_contract_command:t(), State :: state()) -> {noreply, state()}.
handle_cast(Command, State) ->
    {_Result, NewState} = dispatch_command(Command, State),
    {noreply, NewState}.

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

-spec dispatch_command(es_contract_command:t(), state()) ->
    {ok | {error, term()}, state()}.
dispatch_command(Command, State) ->
    Timer = install_passivation(State#state.timeout, State#state.timer_ref),
    process_command(Command, State#state{timer_ref = Timer}).

-spec process_command(es_contract_command:t(), state()) ->
    {ok | {error, term()}, state()}.
process_command(#{id := <<_:128>> = CommandId} = Command, #state{command_ids = Ids} = State) ->
    case is_map_key(CommandId, Ids) of
        true -> {ok, State};
        false -> decide(Command, CommandId, State)
    end;
process_command(_Command, State) ->
    {{error, invalid_command}, State}.

-spec decide(es_contract_command:t(), es_contract_command:id(), state()) ->
    {ok | {error, term()}, state()}.
decide(
    Command,
    CommandId,
    #state{
        aggregate_type = Type,
        aggregate_id = Id,
        domain = Domain,
        store = Store,
        state = DomainState,
        sequence = Sequence,
        now_fun = NowFun,
        command_ids = Seen
    } = State
) ->
    Stream = {Type, Id},
    case es_kernel_domain:handle_command(Domain, Command, DomainState) of
        {ok, []} ->
            {ok, State};
        {ok, Payloads} when is_list(Payloads) ->
            case persist_events(Payloads, {Domain, Store, Stream, Sequence, NowFun}, Command) of
                {ok, NewSequence} ->
                    NewDomainState = lists:foldl(
                        fun(Payload, Acc) -> es_kernel_domain:apply_event(Domain, Payload, Acc) end,
                        DomainState,
                        Payloads
                    ),
                    NewState = State#state{
                        state = NewDomainState,
                        sequence = NewSequence,
                        command_ids = Seen#{CommandId => true}
                    },
                    maybe_save_snapshot(NewState),
                    {ok, NewState};
                {error, {wrong_expected_sequence, _, _}} = Conflict ->
                    Refreshed = replay(State, Sequence + 1),
                    case is_map_key(CommandId, Refreshed#state.command_ids) of
                        true -> {ok, Refreshed};
                        false -> {Conflict, Refreshed}
                    end;
                {error, _} = Error ->
                    {Error, State}
            end;
        {error, _} = Error ->
            check_rejected_command(CommandId, Error, State)
    end.

-spec check_rejected_command(es_contract_command:id(), {error, term()}, state()) ->
    {ok | {error, term()}, state()}.
check_rejected_command(
    CommandId,
    Rejection,
    #state{store = Store, aggregate_type = Type, aggregate_id = Id, sequence = Sequence} = State
) ->
    %% A stale aggregate can reject a command that another writer already committed.
    Find = fun
        (#{metadata := #{command_id := Seen}}, _, _) when Seen =:= CommandId -> true;
        (_, _, Found) -> Found
    end,
    From = Sequence + 1,
    case
        es_kernel_store:fold(Store, {Type, Id}, Find, false, es_contract_range:new(From, infinity))
    of
        {ok, true} -> {ok, replay(State, From)};
        {ok, false} -> {Rejection, State};
        {error, _} = Error -> {Error, State}
    end.

-spec persist_events(
    PayloadEvents :: [es_contract_event:payload()],
    {
        Domain :: es_kernel_registry:domain(),
        StoreContext :: es_kernel_store:store_context(),
        StreamId :: es_contract_event:stream_id(),
        Sequence0 :: es_contract_event:sequence(),
        NowFun :: fun(() -> non_neg_integer())
    },
    es_contract_command:t()
) -> {ok, es_contract_event:sequence()} | {error, term()}.
persist_events(PayloadEvents, {Domain, StoreContext, StreamId, Sequence0, NowFun}, Command) ->
    Tags = maps:get(tags, Command, []),
    Metadata = es_contract_event:metadata_from_command(Command),
    {AggregateType, _AggregateId} = StreamId,
    {Events, _} =
        lists:mapfoldl(
            fun(PayloadEvent, SequenceN) ->
                Now = NowFun(),
                SequenceN1 = SequenceN + 1,
                EventType = es_kernel_domain:event_type(Domain, PayloadEvent),
                Event =
                    es_kernel_store:new_event(
                        StreamId,
                        AggregateType,
                        EventType,
                        SequenceN1,
                        Tags,
                        Now,
                        Metadata,
                        PayloadEvent
                    ),
                {Event, SequenceN1}
            end,
            Sequence0,
            PayloadEvents
        ),
    lists:foreach(
        fun(Event) ->
            logger:info("Persisting Event: ~p", [Event])
        end,
        Events
    ),
    es_kernel_store:append(StoreContext, StreamId, Sequence0, Events).

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
