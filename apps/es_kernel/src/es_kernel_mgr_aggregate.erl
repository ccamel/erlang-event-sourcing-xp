-module(es_kernel_mgr_aggregate).
-moduledoc """
Singleton aggregate manager for the event sourcing kernel.

This module implements a `gen_server` that manages all event-sourced
aggregates. It routes commands to aggregate processes based on the
`aggregate_type` and `aggregate_id` carried by the command and
ensures that each `{aggregate_type, aggregate_id}` pair is handled by at most one
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
    pids :: #{es_contract_command:target() => pid()},
    requests :: gen_server:request_id_collection()
}).

-opaque state() :: #state{}.
-export_type([state/0]).

-doc """
Start the singleton aggregate manager.

- StoreContext is a `{EventStore, SnapshotStore}` tuple.
- Opts configures the aggregate processes:
  - `timeout`: Inactivity delay before passivation, in milliseconds (default: `5000`).
  - `now_fun`: Timestamp function (default: `erlang:system_time(millisecond)`).

Returns `{ok, Pid}` on success, or an error tuple if startup fails.
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
If the target aggregate dies during the call, returns `{error, {aggregate_down, Reason}}`
and evicts the stale PID so a subsequent dispatch will start a fresh aggregate.

The call waits for the aggregate reply; runtimes must bound external execution.
""".
-spec dispatch(ServerRef, Command) -> ok | {error, Reason} when
    ServerRef :: gen_server:server_ref(),
    Command :: es_contract_command:t(),
    Reason :: term().
dispatch(ServerRef, Command) ->
    gen_server:call(ServerRef, Command, infinity).

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
        pids = #{},
        requests = gen_server:reqids_new()
    }}.

-spec handle_call(Command, From, State) ->
    {noreply, State} | {reply, {error, Reason}, State}
when
    Command :: es_contract_command:t(),
    From :: gen_server:from(),
    State :: state(),
    Reason :: term().
handle_call(#{aggregate_type := AggregateType, aggregate_id := AggId} = Command, From, State) ->
    Target = {AggregateType, AggId},
    case ensure_aggregate(Target, State) of
        {ok, Pid, #state{requests = Requests} = NewState} ->
            Pending = gen_server:send_request(Pid, Command, {From, Target, Command}, Requests),
            {noreply, NewState#state{requests = Pending}};
        {error, Reason} ->
            {reply, {error, Reason}, State}
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

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({{aggregate_down, Target}, _Ref, process, Pid, _Reason}, State) ->
    {noreply, evict(Target, Pid, State)};
handle_info(Info, #state{requests = Requests} = State) ->
    case gen_server:check_response(Info, Requests, true) of
        {{reply, Result}, {From, _, _}, Pending} ->
            gen_server:reply(From, Result),
            {noreply, State#state{requests = Pending}};
        {{error, {Reason, Pid}}, {From, Target, Command}, Pending} ->
            NewState = evict(Target, Pid, State#state{requests = Pending}),
            %% Preserve the exit reason shape from gen_server:call/3.
            CallExit = {Reason, {gen_server, call, [Pid, Command, infinity]}},
            gen_server:reply(From, {error, {aggregate_down, CallExit}}),
            {noreply, NewState};
        _ ->
            {noreply, State}
    end.

-spec ensure_aggregate(es_contract_command:target(), state()) ->
    {ok, pid(), state()} | {error, term()}.
ensure_aggregate(
    {AggregateType, AggId} = Target,
    #state{store = StoreContext, pids = Pids, opts = Opts} = State
) ->
    case Pids of
        #{Target := Pid} ->
            {ok, Pid, State};
        #{} ->
            case
                es_kernel_aggregate_sup:start_aggregate(AggregateType, AggId, StoreContext, Opts)
            of
                {ok, Pid} ->
                    erlang:monitor(process, Pid, [{tag, {aggregate_down, Target}}]),
                    {ok, Pid, State#state{pids = Pids#{Target => Pid}}};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

-spec evict(es_contract_command:target(), pid(), state()) -> state().
evict(Target, Pid, #state{pids = Pids} = State) ->
    case Pids of
        #{Target := Pid} -> State#state{pids = maps:remove(Target, Pids)};
        #{} -> State
    end.
