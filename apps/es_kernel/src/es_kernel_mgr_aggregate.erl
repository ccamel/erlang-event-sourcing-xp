-module(es_kernel_mgr_aggregate).
-moduledoc """
Singleton aggregate manager for the event sourcing kernel.

This module implements a `gen_server` that manages all event-sourced
aggregates across domains. It routes commands to aggregate processes
based on the `domain` and `stream_id` carried by the command and
ensures that each `{domain, stream_id}` pair is handled by at most one
aggregate process at a time.

The manager is registered as a singleton and started by the application
supervisor.
""".

-behaviour(gen_server).

-export([
    init/1,
    handle_cast/2,
    handle_call/3,
    handle_info/2,
    terminate/2,
    start_link/2,
    stop/1,
    dispatch/2
]).

-record(state, {
    store :: es_kernel_store:store_context(),
    opts ::
        #{
            timeout => timeout(),
            now_fun => fun(() -> non_neg_integer()),
            snapshot_interval => non_neg_integer()
        },
    pids :: #{{module(), es_contract_event:stream_id()} => pid()}
}).

-opaque state() :: #state{}.
-export_type([state/0]).

-doc """
Starts the singleton aggregate manager with custom options.

- StoreContext is a `{EventStore, SnapshotStore}` tuple.
- Opts is the configuration options:
  - `timeout`: Timeout for operations (default: `infinity`).
  - `now_fun`: Function to get current timestamp (default: system time).

Function returns `{ok, Pid}` on success, or an error tuple if the server fails to start.
The manager is registered with name `es_kernel_mgr_aggregate`.
""".
-spec start_link(StoreContext, Opts) -> gen_server:start_ret() when
    StoreContext :: es_kernel_store:store_context(),
    Opts ::
        #{
            timeout => timeout(),
            now_fun => fun(() -> non_neg_integer()),
            snapshot_interval => non_neg_integer()
        }.
start_link(StoreContext, Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {StoreContext, Opts}, []).

-doc """
Stops the aggregate manager.

- ServerRef is a reference to the gen_server (pid or registered name).
""".
-spec stop(ServerRef) -> ok when ServerRef :: gen_server:server_ref().
stop(ServerRef) ->
    gen_server:stop(ServerRef).

-doc """
Dispatches a command to the appropriate aggregate instance.

- ServerRef is the pid or registered name of the manager process.
- Command is the command to dispatch.

Returns `ok` on success, or `{error, Reason}` if routing or execution fails.
""".
-spec dispatch(ServerRef, Command) -> ok | {error, Reason} when
    ServerRef :: gen_server:server_ref(),
    Command :: es_contract_command:t(),
    Reason :: term().
dispatch(ServerRef, Command) ->
    gen_server:call(ServerRef, Command).

-doc """
Initializes the aggregate manager state from the store context and options.
""".
-spec init({StoreContext, Opts}) -> {ok, State} when
    StoreContext :: es_kernel_store:store_context(),
    Opts ::
        #{
            timeout => timeout(),
            now_fun => fun(() -> non_neg_integer()),
            snapshot_interval => non_neg_integer()
        },
    State :: state().
init({StoreContext, Opts}) ->
    {ok, #state{
        store = StoreContext,
        opts = Opts,
        pids = #{}
    }}.

-spec handle_call(Command, From, State) ->
    {reply, ok | {error, Reason}, State}
when
    Command :: es_contract_command:t(),
    From :: {pid(), term()},
    State :: state(),
    Reason :: term().
handle_call(#{domain := Aggregate, stream_id := Id} = Command, _From, State) ->
    case ensure_and_dispatch(Aggregate, Id, Command, State) of
        {ok, Result, NewState} ->
            {reply, Result, NewState};
        {error, Reason, NewState} ->
            {reply, {error, Reason}, NewState}
    end;
handle_call(_InvalidCommand, _From, State) ->
    {reply, {error, invalid_command}, State}.

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

On `{'DOWN', ...}` from an aggregate process, removes it from the
internal registry so future commands will cause a new process to be
started if needed.
""".
-spec handle_info(Info, State) -> {noreply, State} when
    Info :: {'DOWN', _Ref, process, Pid, _Reason},
    State :: state(),
    Pid :: pid().
handle_info({'DOWN', _Ref, process, Pid, _Reason}, #state{pids = Pids} = State) ->
    KeyToRemove = maps:filter(fun(_, ThisPid) -> ThisPid =:= Pid end, Pids),
    case maps:keys(KeyToRemove) of
        [Key] ->
            NewPids = maps:remove(Key, Pids),
            {noreply, State#state{pids = NewPids}};
        [] ->
            {noreply, State}
    end;
handle_info(_Any, State) ->
    {noreply, State}.

-doc """
Ensures an aggregate process exists for the `{domain, stream_id}` pair
and dispatches the command, starting a new process if needed.

Returns `{ok, Result, State}` or `{error, Reason, State}`.
""".
-spec ensure_and_dispatch(Aggregate, Id, Command, State) ->
    {ok, Result, State} | {error, Reason, State}
when
    Aggregate :: module(),
    Id :: es_contract_event:stream_id(),
    Command :: es_contract_command:t(),
    Result :: ok | {error, Reason},
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
    Key = {Aggregate, Id},
    case maps:get(Key, Pids, undefined) of
        undefined ->
            case start_aggregate(Aggregate, StoreContext, Id, Opts) of
                {ok, Pid} ->
                    Result = forward(Pid, Command),
                    NewPids = maps:put(Key, Pid, Pids),
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

Returns the result of the aggregate's `execute/2` function:
`ok` on success or `{error, Reason}` on failure.
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
            now_fun => fun(() -> non_neg_integer()),
            snapshot_interval => non_neg_integer()
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
