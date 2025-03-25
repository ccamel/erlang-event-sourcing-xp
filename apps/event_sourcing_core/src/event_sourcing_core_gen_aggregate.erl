-module(event_sourcing_core_gen_aggregate).

-behaviour(gen_server).

-export([start_link/3, start_link/4, handle_info/2, init/1, handle_call/3, handle_cast/2,
         code_change/3, terminate/2]).

-export_type([command/0, aggregate_state/0, stream_id/0, state/0]).

-define(SEQUENCE_START, 0).
-define(INACTIVITY_TIMEOUT, 5000).

-type command() :: term().
-type event_payload() :: term().
-type aggregate_state() :: term().
-type stream_id() :: event_sourcing_store:stream_id().
-type sequence() :: event_sourcing_store:sequence().

%% @doc
%% This callback function is used to initialize the state of the aggregate.
%% It should return the initial state of the aggregate.
-callback init() -> aggregate_state().
%% @doc
%% This callback function is used to get the event type from a command.
%% It takes a command and returns the event type.
-callback event_type(event_payload()) -> atom().
%% @doc
%% This callback function is used to handle commands in the aggregate.
%% It takes a command and the current state as arguments and returns either
%% an ok tuple with a list of events or an error tuple with a term describing the error.
-callback handle_command(Command, State) -> {ok, [event_payload()]} | {error, term()}
    when Command :: command(),
         State :: aggregate_state().
%% @doc
%% This callback function is used to apply events to the aggregate state.
%% It takes an event and the current state as arguments and returns the new state.
-callback apply_event(Event, State0) -> State1
    when Event :: event_payload(),
         State0 :: aggregate_state(),
         State1 :: aggregate_state().

%% @doc Starts an aggregate process with a given timeout.
%%
%% @param Aggregate The aggregate module implementing the behavior.
%% @param Store The event-store module.
%% @param Id The unique identifier for the aggregate instance.
%% @param Timeout The inactivity timeout in milliseconds before passivation.
%% @return `{ok, Pid}` if successful, `{error, Reason}` otherwise.
-spec start_link(Aggregate :: module(),
                 Store :: module(),
                 Id :: stream_id(),
                 Timeout :: timeout()) ->
                    {ok, pid()} | {error, term()}.
start_link(Aggregate, Store, Id, Timeout) ->
    gen_server:start_link(?MODULE, {Aggregate, Store, Id, Timeout}, []).

%% @doc
%% Starts a new aggregate process.
%%
%% @param Aggregate The aggregate module to start.
%% @param Store The persistence module (event-store) implementing event retrieval.
%% @param Id The unique identifier for the aggregate instance.
-spec start_link(Aggregate :: module(), Store :: module(), Id :: stream_id()) ->
                    {ok, pid()} | {error, term()}.
start_link(Aggregate, Store, Id) ->
    start_link(Aggregate, Store, Id, ?INACTIVITY_TIMEOUT).

-record(state,
        {aggregate :: module(),
         store :: module(),
         id :: stream_id(),
         state :: aggregate_state(),
         sequence = ?SEQUENCE_START :: non_neg_integer(),
         timeout = ?INACTIVITY_TIMEOUT :: timeout(),
         timer_ref = undefined :: reference()}).

-opaque state() :: #state{}.

%% @doc
%% Initializes the aggregate process.
%%
%% Retrieves all events for the aggregate from the persistence layer and applies them
%% sequentially to rehydrate the aggregate's state.
%%
%% @param Aggregate The aggregate module implementing the domain logic.
%% @param Store The persistence module (store) implementing event retrieval.
%% @param Id The unique identifier for the aggregate.
%% @param Timeout The inactivity timeout (in milliseconds) for the aggregate process.
%%
%% @return {ok, state()} on success,
%%         Returns {stop, Reason} on failure.

-spec init({module(), module(), stream_id(), timeout()}) -> {ok, state()}.
init({Aggregate, Store, Id, Timeout}) ->
    State0 = Aggregate:init(),
    {State1, Sequence1} =
        event_sourcing_store:retrieve_and_fold_events(Store,
                                                      Id,
                                                      [],
                                                      fun(Event, {StateAcc, _SeqAcc}) ->
                                                         {Aggregate:apply_event(
                                                              event_sourcing_store:payload(Event),
                                                              StateAcc),
                                                          event_sourcing_store:sequence(Event)}
                                                      end,
                                                      {State0, ?SEQUENCE_START}),
    TimerRef = install_passivation(Timeout, undefined),
    {ok,
     #state{aggregate = Aggregate,
            store = Store,
            id = Id,
            state = State1,
            sequence = Sequence1,
            timeout = Timeout,
            timer_ref = TimerRef}}.

%% @doc
%% Handles a call to the aggregate.
%%
%% @param Command The command to be processed by the aggregate.
%% @param From The caller's process identifier and a reference term.
%% @param State The current state of the aggregate.
%%
%% @return A tuple indicating the result of the call and the new state of the aggregate.
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

%% @doc
%% Handles a cast message (asynchronous message) sent to the aggregate process.
%%
%% @param Command The command to be processed by the aggregate.
%% @param State The current state of the aggregate process.
%%
%% @return A tuple indicating no reply and the updated state of the aggregate process.
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

%% @doc
%% Installs a passivation mechanism for the aggregate.
%%
%% @param Timeout The time in milliseconds after which the aggregate should be passivated.
%% @param TimerRef A reference to the timer that will trigger the passivation.
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

%% @doc
%% Handles a command for the given aggregate.
%%
%% @param State The current state of the server.
%% @param Command The command to be handled.
%% @return The new state and sequence of the aggregate after the command is applied.
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
                       sequence = Sequence0},
                Command) ->
    CmdResult = Aggregate:handle_command(Command, State0),
    case CmdResult of
        {ok, []} ->
            {ok, {State0, Sequence0}};
        {ok, PayloadEvents} when is_list(PayloadEvents) ->
            {Events, _} =
                lists:foldl(fun(PayloadEvent, {Events, SequenceN}) ->
                               Now = erlang:system_time(millisecond),
                               SequenceN1 = SequenceN + 1,
                               EventType = Aggregate:event_type(PayloadEvent),
                               Event =
                                   event_sourcing_store:new_event(Id,
                                                                  Aggregate,
                                                                  EventType,
                                                                  SequenceN1,
                                                                  Now,
                                                                  PayloadEvent),
                               {[Event | Events], SequenceN1}
                            end,
                            {[], Sequence0},
                            PayloadEvents),
            ok = event_sourcing_store:persist_events(Store, Id, Events),
            {State1, Sequence1} = apply_events(PayloadEvents, {Aggregate, State0, Sequence0}),
            {ok, {State1, Sequence1}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec apply_events(Event :: [event_payload()],
                   {Aggregate :: module(), State :: aggregate_state(), Sequence :: sequence()}) ->
                      {State :: aggregate_state(), Sequence :: sequence()}.
apply_events(Events, {Aggregate, State0, Sequence0}) ->
    lists:foldl(fun(Event, {StateN, SequenceN}) ->
                   StateN1 = Aggregate:apply_event(Event, StateN),
                   SequenceN1 = SequenceN + 1,
                   {StateN1, SequenceN1}
                end,
                {State0, Sequence0},
                Events).
