-module(event_sourcing_core_aggregate).

-include_lib("event_sourcing_core.hrl").

-behaviour(gen_server).

-export([start_link/3, start_link/4, handle_info/2, init/1, handle_call/3, handle_cast/2,
         code_change/3, terminate/2, dispatch/2]).

-export_type([command/0, aggregate_state/0, stream_id/0, state/0, sequence/0,
              timestamp/0]).

-define(SEQUENCE_ZERO, 0).
-define(INACTIVITY_TIMEOUT, 5000).

-type aggregate_state() :: event_sourcing_core_aggregate_behaviour:aggregate_state().

-doc """
Starts an aggregate process with a given timeout.

- Aggregate is the aggregate module implementing the behavior.
- Store is the event-store module.
- Id is the unique identifier for the aggregate instance.
- Timeout is the inactivity timeout in milliseconds before passivation.

Function returns `{ok, Pid}` if successful, `{error, Reason}` otherwise.
""".
-spec start_link(Aggregate, Store, Id, Opts) -> gen_server:start_ret()
    when Aggregate :: module(),
         Store :: module(),
         Id :: stream_id(),
         Opts ::
             #{timeout => timeout(),
               sequence_zero => fun(() -> sequence()),
               sequence_next => fun((sequence()) -> sequence()),
               now_fun => fun(() -> timestamp())}.
start_link(Aggregate, Store, Id, Opts) ->
    gen_server:start_link(?MODULE, {Aggregate, Store, Id, Opts}, []).

-doc """
Starts a new aggregate process.

- Aggregate is the aggregate module to start.
- Store is the persistence module (event-store) implementing event retrieval.
- Id is the unique identifier for the aggregate instance.
""".
-spec start_link(Aggregate :: module(), Store :: module(), Id :: stream_id()) ->
                    gen_server:start_ret().
start_link(Aggregate, Store, Id) ->
    start_link(Aggregate, Store, Id, #{}).

-spec dispatch(Pid, Command) -> {ok, Result} | {error, Reason}
    when Pid :: pid(),
         Command :: command(),
         Result :: term(),
         Reason :: term().
dispatch(Pid, Command) ->
    gen_server:call(Pid, Command).

-record(state,
        {aggregate :: module(),
         store :: module(),
         id :: stream_id(),
         state :: aggregate_state(),
         sequence = ?SEQUENCE_ZERO :: non_neg_integer(),
         timeout = ?INACTIVITY_TIMEOUT :: timeout(),
         sequence_zero :: fun(() -> sequence()),
         sequence_next :: fun((sequence()) -> sequence()),
         now_fun :: fun(() -> timestamp()),
         timer_ref = undefined :: reference()}).

-opaque state() :: #state{}.

-doc """
Initializes the aggregate process.

Retrieves all events for the aggregate from the persistence layer and applies them
sequentially to rehydrate the aggregate's state.

- Aggregate is the aggregate module implementing the domain logic.
- Store is the persistence module (store) implementing event retrieval.
- Id is the unique identifier for the aggregate.
- Timeout is the inactivity timeout (in milliseconds) for the aggregate process.

Function returns {ok, state()} on success, and returns {stop, Reason} on failure.
""".
-spec init({module(),
            module(),
            stream_id(),
            #{timeout => timeout(),
              sequence_zero => fun(() -> sequence()),
              sequence_next => fun((sequence()) -> sequence()),
              now_fun => fun(() -> timestamp())}}) ->
              {ok, state()}.
init({Aggregate, Store, Id, Opts}) ->
    State0 = Aggregate:init(),
    SequenceZero = maps:get(sequence_zero, Opts, fun() -> ?SEQUENCE_ZERO end),
    SequenceNext = maps:get(sequence_next, Opts, fun(Sequence) -> Sequence + 1 end),
    FoldFun =
        fun(Event, {StateAcc, _SeqAcc}) ->
           {Aggregate:apply_event(
                event_sourcing_core_store:payload(Event), StateAcc),
            event_sourcing_core_store:sequence(Event)}
        end,
    {State1, Sequence1} =
        event_sourcing_core_store:retrieve_and_fold_events(Store,
                                                           Id,
                                                           #{},
                                                           FoldFun,
                                                           {State0, SequenceZero()}),
    Timeout = maps:get(timeout, Opts, ?INACTIVITY_TIMEOUT),
    TimerRef = install_passivation(Timeout, undefined),
    {ok,
     #state{aggregate = Aggregate,
            store = Store,
            id = Id,
            state = State1,
            sequence = Sequence1,
            timeout = Timeout,
            sequence_zero = SequenceZero,
            sequence_next = SequenceNext,
            now_fun = maps:get(now_fun, Opts, fun() -> erlang:system_time() end),
            timer_ref = TimerRef}}.

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
            {reply,
             ok,
             State#state{state = State1,
                         sequence = Sequence1,
                         timer_ref = NewTimerRef}};
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
            {noreply,
             State#state{state = State1,
                         sequence = Sequence1,
                         timer_ref = NewTimerRef}};
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
-spec install_passivation(Timeout, TimerRef0) -> TimerRef1
    when Timeout :: non_neg_integer(),
         TimerRef0 :: reference() | undefined,
         TimerRef1 :: reference().
install_passivation(Timeout, TimerRef) ->
    _ = case TimerRef of
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
-spec process_command(State, Command) -> {ok, Result} | {error, Reason}
    when State :: state(),
         Command :: command(),
         State1 :: aggregate_state(),
         Sequence1 :: sequence(),
         Result :: {State1, Sequence1},
         Reason :: term().
process_command(#state{aggregate = Aggregate,
                       store = Store,
                       id = Id,
                       state = State0,
                       sequence = Sequence0,
                       sequence_next = SequenceNext},
                Command) ->
    CmdResult = Aggregate:handle_command(Command, State0),
    case CmdResult of
        {ok, []} ->
            {ok, {State0, Sequence0}};
        {ok, PayloadEvents} when is_list(PayloadEvents) ->
            {Events, _} =
                lists:foldl(fun(PayloadEvent, {Events, SequenceN}) ->
                               Now = erlang:system_time(millisecond),
                               SequenceN1 = SequenceNext(SequenceN),
                               EventType = Aggregate:event_type(PayloadEvent),
                               Event =
                                   event_sourcing_core_store:new_event(Id,
                                                                       Aggregate,
                                                                       EventType,
                                                                       SequenceN1,
                                                                       Now,
                                                                       PayloadEvent),
                               {[Event | Events], SequenceN1}
                            end,
                            {[], Sequence0},
                            PayloadEvents),
            ok = event_sourcing_core_store:persist_events(Store, Id, Events),
            {State1, Sequence1} =
                apply_events(PayloadEvents, {Aggregate, State0, Sequence0, SequenceNext}),
            {ok, {State1, Sequence1}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec apply_events(Event :: [event_payload()],
                   {Aggregate :: module(),
                    State :: aggregate_state(),
                    Sequence :: sequence(),
                    SequenceNext :: fun((sequence()) -> sequence())}) ->
                      {State :: aggregate_state(), Sequence :: sequence()}.
apply_events(Events, {Aggregate, State0, Sequence0, SequenceNext}) ->
    lists:foldl(fun(Event, {StateN, SequenceN}) ->
                   StateN1 = Aggregate:apply_event(Event, StateN),
                   SequenceN1 = SequenceNext(SequenceN),
                   {StateN1, SequenceN1}
                end,
                {State0, Sequence0},
                Events).
