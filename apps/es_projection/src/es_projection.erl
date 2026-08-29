-module(es_projection).

-moduledoc """
Projection runtime built on the global event log.

`run_once/3` is an independent fold that returns its projection state and never
reads or writes checkpoints. `start/3` and `start_link/3` run fail-fast,
at-least-once continuous consumers. A continuous consumer requires a checkpoint
store configured in its options or the `es_projection` application environment.

Projection callback state is opaque and is never persisted by this runtime.
Continuous projections must durably update their own materialized views before
returning `{ok, NewState}`; the runner then commits the global position.
""".

-behaviour(gen_server).

-export([
    run_once/3,
    start/3,
    start_link/3,
    lookup/1,
    stop/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(DEFAULT_START_POSITION, 0).
-define(DEFAULT_POLL_INTERVAL, 200).

-record(state, {
    store_context :: es_kernel_store:store_context(),
    projection_module :: module(),
    projection_name :: atom(),
    checkpoint_store :: module(),
    projection_state :: es_contract_projection:projection_state(),
    next_position :: es_contract_event_store:position(),
    last_position :: es_contract_event_store:position() | undefined,
    poll_interval :: pos_integer()
}).

-opaque state() :: #state{}.
-export_type([options/0, state/0]).

-type options() :: #{
    checkpoint_store => module(),
    start_position => es_contract_event_store:position(),
    poll_interval => pos_integer(),
    name => atom() | undefined
}.

-doc """
Fold the global event log from `start_position` and return its projection state.

Each call is independent: it initializes the projection and never loads or
persists a checkpoint.
""".
-spec run_once(StoreContext, ProjectionModule, Options) ->
    {ok, ProjectionState, LastPosition} | {error, Reason}
when
    StoreContext :: es_kernel_store:store_context(),
    ProjectionModule :: module(),
    Options :: options(),
    ProjectionState :: es_contract_projection:projection_state(),
    LastPosition :: es_contract_event_store:position() | undefined,
    Reason :: term().
run_once(StoreContext, ProjectionModule, Options) ->
    ProjectionState = ProjectionModule:init(),
    StartPosition = maps:get(start_position, Options, ?DEFAULT_START_POSITION),
    catch_up_once(StoreContext, ProjectionModule, StartPosition, ProjectionState).

-doc """
Start a managed, persistent polling projection runner.

A checkpoint store must be configured with `checkpoint_store` in `Options` or
the `es_projection` application environment. Otherwise this returns
`{error, checkpoint_store_not_configured}`.
""".
-spec start(StoreContext, ProjectionModule, Options) -> {ok, pid()} | {error, Reason} when
    StoreContext :: es_kernel_store:store_context(),
    ProjectionModule :: module(),
    Options :: options(),
    Reason :: term().
start(StoreContext, ProjectionModule, Options) ->
    es_projection_mgr:start_projection(StoreContext, ProjectionModule, Options).

-doc """
Return the pid of a managed projection runner.
""".
-spec lookup(atom()) -> {ok, pid()} | {error, not_found}.
lookup(ProjectionName) ->
    es_projection_mgr:lookup(ProjectionName).

-doc """
Start a linked, persistent polling projection runner.

A checkpoint store must be configured with `checkpoint_store` in `Options` or
the `es_projection` application environment. Otherwise this returns
`{error, checkpoint_store_not_configured}`.
""".
-spec start_link(StoreContext, ProjectionModule, Options) -> gen_server:start_ret() when
    StoreContext :: es_kernel_store:store_context(),
    ProjectionModule :: module(),
    Options :: options().
start_link(StoreContext, ProjectionModule, Options) ->
    Args = {StoreContext, ProjectionModule, Options},
    case maps:get(name, Options, undefined) of
        undefined ->
            gen_server:start_link(?MODULE, Args, []);
        Name when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, Args, [])
    end.

-doc """
Stop a polling projection runner.

When passed an atom, the managed projection with that name is stopped. Other
server references are stopped directly. If no projection manager is running,
an atom is treated as a locally registered runner name.
""".
-spec stop(gen_server:server_ref()) -> ok | {error, not_found}.
stop(ProjectionName) when is_atom(ProjectionName) ->
    case erlang:whereis(es_projection_mgr) of
        undefined ->
            stop_local_or_not_found(ProjectionName);
        _Pid ->
            case es_projection_mgr:stop_projection(ProjectionName) of
                ok ->
                    ok;
                {error, not_found} ->
                    stop_local_or_not_found(ProjectionName)
            end
    end;
stop(ServerRef) ->
    gen_server:stop(ServerRef).

-spec init({StoreContext, ProjectionModule, Options}) ->
    {ok, state()} | {stop, Reason}
when
    StoreContext :: es_kernel_store:store_context(),
    ProjectionModule :: module(),
    Options :: options(),
    Reason :: term().
init({StoreContext, ProjectionModule, Options}) ->
    case init_runtime(StoreContext, ProjectionModule, Options) of
        {ok, State} ->
            self() ! tick,
            {ok, State};
        {error, Reason} ->
            {stop, Reason}
    end.

-spec handle_call(term(), {pid(), term()}, state()) -> {reply, {error, unknown_call}, state()}.
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()} | {stop, term(), state()}.
handle_info(tick, State) ->
    case catch_up(State) of
        {ok, ProjectionState, LastPosition} ->
            NextPosition = next_position(LastPosition, State#state.next_position),
            erlang:send_after(State#state.poll_interval, self(), tick),
            {noreply, State#state{
                projection_state = ProjectionState,
                last_position = LastPosition,
                next_position = NextPosition
            }};
        {error, Reason} ->
            {stop, Reason, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) ->
    ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-spec init_runtime(es_kernel_store:store_context(), module(), options()) ->
    {ok, state()} | {error, term()}.
init_runtime(StoreContext, ProjectionModule, Options) ->
    case configured_checkpoint_store(Options) of
        {ok, CheckpointStore} ->
            StartPosition = maps:get(start_position, Options, ?DEFAULT_START_POSITION),
            PollInterval = maps:get(poll_interval, Options, ?DEFAULT_POLL_INTERVAL),
            ProjectionName = ProjectionModule:name(),
            case ensure_checkpoint_store_started(CheckpointStore) of
                ok ->
                    case load_next_position(CheckpointStore, ProjectionName, StartPosition) of
                        {ok, NextPosition, LastPosition} ->
                            ProjectionState = ProjectionModule:init(),
                            {ok, #state{
                                store_context = StoreContext,
                                projection_module = ProjectionModule,
                                projection_name = ProjectionName,
                                checkpoint_store = CheckpointStore,
                                projection_state = ProjectionState,
                                next_position = NextPosition,
                                last_position = LastPosition,
                                poll_interval = PollInterval
                            }};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec configured_checkpoint_store(options()) -> {ok, module()} | {error, term()}.
configured_checkpoint_store(Options) ->
    case maps:find(checkpoint_store, Options) of
        {ok, CheckpointStore} ->
            validate_checkpoint_store(CheckpointStore);
        error ->
            case application:get_env(es_projection, checkpoint_store) of
                {ok, CheckpointStore} ->
                    validate_checkpoint_store(CheckpointStore);
                undefined ->
                    {error, checkpoint_store_not_configured}
            end
    end.

-spec validate_checkpoint_store(term()) -> {ok, module()} | {error, invalid_checkpoint_store}.
validate_checkpoint_store(CheckpointStore) when is_atom(CheckpointStore) ->
    {ok, CheckpointStore};
validate_checkpoint_store(_) ->
    {error, invalid_checkpoint_store}.

-spec stop_local_or_not_found(atom()) -> ok | {error, not_found}.
stop_local_or_not_found(Name) ->
    case erlang:whereis(Name) of
        undefined ->
            {error, not_found};
        _Pid ->
            gen_server:stop(Name)
    end.

-spec ensure_checkpoint_store_started(module()) -> ok | {error, term()}.
ensure_checkpoint_store_started(CheckpointStore) ->
    case code:ensure_loaded(CheckpointStore) of
        {module, CheckpointStore} ->
            case erlang:function_exported(CheckpointStore, start, 0) of
                true ->
                    CheckpointStore:start();
                false ->
                    ok
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec load_next_position(module(), atom(), es_contract_event_store:position()) ->
    {ok, NextPosition, LastPosition} | {error, term()}
when
    NextPosition :: es_contract_event_store:position(),
    LastPosition :: es_contract_event_store:position() | undefined.
load_next_position(CheckpointStore, ProjectionName, StartPosition) ->
    case CheckpointStore:load_checkpoint(ProjectionName) of
        {ok, LastPosition} ->
            {ok, max(StartPosition, LastPosition + 1), LastPosition};
        {error, not_found} ->
            {ok, StartPosition, undefined};
        {error, Reason} ->
            {error, Reason}
    end.

-spec catch_up_once(
    es_kernel_store:store_context(),
    module(),
    es_contract_event_store:position(),
    es_contract_projection:projection_state()
) ->
    {ok, es_contract_projection:projection_state(), es_contract_event_store:position() | undefined}
    | {error, term()}.
catch_up_once(StoreContext, ProjectionModule, StartPosition, ProjectionState) ->
    Range = es_contract_range:new(StartPosition, infinity),
    Acc0 = {ok, ProjectionState, undefined},
    FoldFun = fun(Event, Position, Acc) ->
        process_once_event(Event, Position, Acc, ProjectionModule)
    end,
    case es_kernel_store:fold_all(StoreContext, FoldFun, Acc0, Range) of
        {ok, {ok, FinalProjectionState, LastPosition}} ->
            {ok, FinalProjectionState, LastPosition};
        {ok, {error, Reason}} ->
            {error, Reason};
        {error, Reason} ->
            {error, Reason}
    end.

-spec process_once_event(
    es_contract_event:t(),
    es_contract_event_store:position(),
    {ok, es_contract_projection:projection_state(), es_contract_event_store:position() | undefined}
    | {error, term()},
    module()
) ->
    {ok, es_contract_projection:projection_state(), es_contract_event_store:position()}
    | {error, term()}.
process_once_event(_Event, _Position, {error, Reason}, _ProjectionModule) ->
    {error, Reason};
process_once_event(Event, Position, {ok, ProjectionState, _LastPosition}, ProjectionModule) ->
    case should_process(ProjectionModule, Event) of
        true ->
            case ProjectionModule:handle_event(Event, Position, ProjectionState) of
                {ok, NewProjectionState} ->
                    {ok, NewProjectionState, Position};
                {error, Reason} ->
                    {error, {handle_event_failed, Position, Reason}}
            end;
        false ->
            {ok, ProjectionState, Position}
    end.

-spec catch_up(state()) -> {ok, ProjectionState, LastPosition} | {error, Reason} when
    ProjectionState :: es_contract_projection:projection_state(),
    LastPosition :: es_contract_event_store:position() | undefined,
    Reason :: term().
catch_up(#state{next_position = NextPosition} = State) ->
    Range = es_contract_range:new(NextPosition, infinity),
    Acc0 = {ok, State#state.projection_state, State#state.last_position},
    FoldFun = fun(Event, Position, Acc) -> process_event(Event, Position, Acc, State) end,
    case es_kernel_store:fold_all(State#state.store_context, FoldFun, Acc0, Range) of
        {ok, {ok, ProjectionState, LastPosition}} ->
            {ok, ProjectionState, LastPosition};
        {ok, {error, Reason}} ->
            {error, Reason};
        {error, Reason} ->
            {error, Reason}
    end.

-spec process_event(
    es_contract_event:t(),
    es_contract_event_store:position(),
    {ok, ProjectionState, LastPosition} | {error, Reason},
    state()
) ->
    {ok, NewProjectionState, NewLastPosition} | {error, Reason}
when
    ProjectionState :: es_contract_projection:projection_state(),
    NewProjectionState :: es_contract_projection:projection_state(),
    LastPosition :: es_contract_event_store:position() | undefined,
    NewLastPosition :: es_contract_event_store:position(),
    Reason :: term().
process_event(_Event, _Position, {error, Reason}, _State) ->
    {error, Reason};
process_event(Event, Position, {ok, ProjectionState, _LastPosition}, State) ->
    case should_process(State#state.projection_module, Event) of
        true ->
            handle_projection_event(Event, Position, ProjectionState, State);
        false ->
            checkpoint(Position, ProjectionState, State)
    end.

-spec should_process(module(), es_contract_event:t()) -> boolean().
should_process(ProjectionModule, Event) ->
    case erlang:function_exported(ProjectionModule, event_filter, 1) of
        true ->
            ProjectionModule:event_filter(Event);
        false ->
            true
    end.

-spec handle_projection_event(
    es_contract_event:t(),
    es_contract_event_store:position(),
    es_contract_projection:projection_state(),
    state()
) ->
    {ok, es_contract_projection:projection_state(), es_contract_event_store:position()}
    | {error, term()}.
handle_projection_event(Event, Position, ProjectionState, State) ->
    ProjectionModule = State#state.projection_module,
    case ProjectionModule:handle_event(Event, Position, ProjectionState) of
        {ok, NewProjectionState} ->
            checkpoint(Position, NewProjectionState, State);
        {error, Reason} ->
            {error, {handle_event_failed, Position, Reason}}
    end.

-spec checkpoint(
    es_contract_event_store:position(),
    es_contract_projection:projection_state(),
    state()
) ->
    {ok, es_contract_projection:projection_state(), es_contract_event_store:position()}
    | {error, term()}.
checkpoint(Position, ProjectionState, State) ->
    CheckpointStore = State#state.checkpoint_store,
    ProjectionName = State#state.projection_name,
    case CheckpointStore:store_checkpoint(ProjectionName, Position) of
        ok ->
            {ok, ProjectionState, Position};
        {error, Reason} ->
            {error, {checkpoint_failed, Position, Reason}}
    end.

-spec next_position(
    es_contract_event_store:position() | undefined,
    es_contract_event_store:position()
) ->
    es_contract_event_store:position().
next_position(undefined, CurrentNextPosition) ->
    CurrentNextPosition;
next_position(LastPosition, CurrentNextPosition) ->
    max(CurrentNextPosition, LastPosition + 1).
