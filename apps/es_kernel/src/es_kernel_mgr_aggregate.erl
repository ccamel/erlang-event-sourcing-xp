-module(es_kernel_mgr_aggregate).
-moduledoc """
This module implements a `gen_server` that manages event-sourcing aggregates.

It acts as a router and supervisor for aggregate processes, dispatching commands
to the appropriate aggregate instance based on a stream ID. It ensures that each
stream ID maps to a single aggregate process, starting new ones as needed and
monitoring them for crashes.
""".

-behaviour(gen_server).

-export([
    init/1,
    handle_cast/2,
    handle_call/3,
    handle_info/2,
    terminate/2,
    start_link/4,
    start_link/3,
    stop/1,
    dispatch/2
]).

-record(state, {
    aggregate :: module(),
    store :: es_kernel_store:store_context(),
    router :: module(),
    opts ::
        #{
            timeout => timeout(),
            now_fun => fun(() -> non_neg_integer())
        },
    pids :: #{es_contract_event:stream_id() => pid()}
}).

-opaque state() :: #state{}.
-export_type([state/0]).

-doc """
Starts the aggregate manager with custom options.

- Aggregate is the module implementing the aggregate logic.
- StoreContext is a `{EventStore, SnapshotStore}` tuple.
- Router is the module extracting routing info from commands.
- Opts is the configuration options:
  - `timeout`: Timeout for operations (default: `infinity`).
  - `now_fun`: Function to get current timestamp (default: system time).

Function returns `{ok, Pid}` on success, or an error tuple if the server fails to start.
""".
-spec start_link(Aggregate, StoreContext, Router, Opts) -> gen_server:start_ret() when
    Aggregate :: module(),
    StoreContext :: es_kernel_store:store_context(),
    Router :: module(),
    Opts ::
        #{
            timeout => timeout(),
            now_fun => fun(() -> non_neg_integer())
        }.
start_link(Aggregate, StoreContext, Router, Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {Aggregate, StoreContext, Router, Opts}, []).

-doc """
Starts the aggregate manager with the given aggregate, store, and router modules,
using default options.

- Aggregate is the module implementing the aggregate logic.
- StoreContext follows the same `{EventStore, SnapshotStore}` convention.
- Router is the module extracting routing info from commands.

Function returns `{ok, Pid}` on success, or an error tuple if the server fails to start.
""".
-spec start_link(Aggregate, StoreContext, Router) -> gen_server:start_ret() when
    Aggregate :: module(),
    StoreContext :: es_kernel_store:store_context(),
    Router :: module().
start_link(Aggregate, StoreContext, Router) ->
    start_link(Aggregate, StoreContext, Router, #{}).

-doc """
Stops the aggregate manager.

- ServerRef is a Reference to the gen_server (e.g., pid or name).

Function returns `ok` on success; may throw an exception if the server is unreachable.
""".
-spec stop(ServerRef) -> ok when ServerRef :: gen_server:server_ref().
stop(ServerRef) ->
    gen_server:stop(ServerRef).

-doc """
Dispatches a command to the appropriate aggregate instance.

Routes the command via the manager to the aggregate process for the stream ID
extracted by the router module.

- Pid is the pid of the manager process.
- Command is the command to dispatch.

Returns `{ok, Result}` on success, or `{error, Reason}` if routing or execution fails.
""".
-spec dispatch(Pid, Command) -> {ok, Result} | {error, Reason} when
    Pid :: pid(),
    Command :: es_contract_command:t(),
    Result :: term(),
    Reason :: term().
dispatch(Pid, Command) ->
    gen_server:call(Pid, Command).

-doc """
Initializes the aggregate manager state.

- Args is the tuple containing the aggregate, store, router modules, and options.

Function returns `{ok, State}` with an initialized state record.
""".
-spec init({Aggregate, StoreContext, Router, Opts}) -> {ok, State} when
    Aggregate :: module(),
    StoreContext :: es_kernel_store:store_context(),
    Router :: module(),
    Opts ::
        #{
            timeout => timeout(),
            now_fun => fun(() -> non_neg_integer())
        },
    State :: state().
init({Aggregate, StoreContext, Router, Opts}) ->
    {ok, #state{
        aggregate = Aggregate,
        store = StoreContext,
        router = Router,
        opts = Opts,
        pids = #{}
    }}.

-spec handle_call(Command, From, State) ->
    {reply, {ok, Result} | {error, Reason}, State}
when
    Command :: es_contract_command:t(),
    From :: {pid(), term()},
    State :: state(),
    Result :: term(),
    Reason :: term().
handle_call(Command, _From, #state{aggregate = Aggregate, router = Router} = State) ->
    case Router:extract_routing(Command) of
        {ok, {Aggregate, Id}} ->
            case ensure_and_dispatch(Aggregate, Id, Command, State) of
                {ok, Result, NewState} ->
                    {reply, Result, NewState};
                {error, Reason, NewState} ->
                    {reply, {error, Reason}, NewState}
            end;
        {ok, {WrongAgg, _Id}} when WrongAgg =/= Aggregate ->
            {reply, {error, wrong_aggregate}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

-spec handle_cast(Command, State) -> {noreply, State} when
    Command :: es_contract_command:t(),
    State :: state().
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec terminate(Reason, State) -> ok when
    Reason :: term(),
    State :: state().
terminate(_Reason, _State) ->
    ok.

-doc """
Handles process monitoring messages.

Removes the pid of a downed aggregate from the state's `pids` map.

- Info represents the `'DOWN'` message from a monitored process.

Function returns `{noreply, State}` with updated state.
""".
-spec handle_info(Info, State) -> {noreply, State} when
    Info :: {'DOWN', _Ref, process, Pid, _Reason},
    State :: state(),
    Pid :: pid().
handle_info({'DOWN', _Ref, process, Pid, _Reason}, #state{pids = Pids} = State) ->
    IdToRemove = maps:filter(fun(_, ThisPid) -> ThisPid =:= Pid end, Pids),
    case maps:keys(IdToRemove) of
        [Id] ->
            NewPids = maps:remove(Id, Pids),
            {noreply, State#state{pids = NewPids}};
        [] ->
            {noreply, State}
    end;
handle_info(_Any, State) ->
    {noreply, State}.

-doc """
Ensures an aggregate process exists for the stream ID and dispatches the command.

Starts a new aggregate if none exists, then forwards the command.

Returns `{ok, Result, State}` or `{error, Reason, State}`.
""".
-spec ensure_and_dispatch(Aggregate, Id, Command, State) ->
    {ok, Result, State} | {error, Reason, State}
when
    Aggregate :: module(),
    Id :: es_contract_event:stream_id(),
    Command :: es_contract_command:t(),
    Result :: term(),
    State :: state(),
    Reason :: term().
ensure_and_dispatch(
    Aggregate,
    Id,
    Command,
    #state{
        store = StoreContext,
        pids = Pids,
        opts = Opts
    } =
        State
) ->
    case maps:get(Id, Pids, undefined) of
        undefined ->
            case start_aggregate(Aggregate, StoreContext, Id, Opts) of
                {ok, Pid} ->
                    Result = forward(Pid, Command),
                    NewPids = maps:put(Id, Pid, Pids),
                    {ok, Result, State#state{pids = NewPids}};
                {error, Reason} ->
                    {error, Reason, State}
            end;
        Pid ->
            Result = forward(Pid, Command),
            {ok, Result, State}
    end.

-doc """
Forwards a command to an aggregate process.

Function returns The result of the aggregate's execute function.
""".
-spec forward(Pid, Command) -> ok | {error, Reason} when
    Pid :: pid(),
    Command :: es_contract_command:t(),
    Reason :: term().
forward(Pid, Command) ->
    es_kernel_aggregate:execute(Pid, Command).

-doc """
Starts an aggregate process for a given stream ID.

Uses the es_kernel_aggregate_sup dynamic supervisor to start the aggregate,
ensuring it is properly supervised. Monitors the new process and returns its pid.

Function returns `{ok, Pid}` on success, or `{error, Reason}` on failure.
""".
-spec start_aggregate(Aggregate, StoreContext, Id, Opts) ->
    {ok, Result} | {error, Reason}
when
    Aggregate :: module(),
    StoreContext :: es_kernel_store:store_context(),
    Id :: es_contract_event:stream_id(),
    Opts ::
        #{
            timeout => timeout(),
            now_fun => fun(() -> non_neg_integer())
        },
    Result :: pid(),
    Reason :: term().
start_aggregate(Aggregate, StoreContext, Id, Opts) ->
    case es_kernel_aggregate_sup:start_aggregate(Aggregate, StoreContext, Id, Opts) of
        {ok, Pid} ->
            erlang:monitor(process, Pid),
            {ok, Pid};
        {error, Reason} ->
            {error, Reason}
    end.
