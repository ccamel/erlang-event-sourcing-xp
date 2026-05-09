-module(es_projection_mgr).

-moduledoc """
Singleton manager for projection runner processes.
""".

-behaviour(gen_server).

-export([
    start_link/0,
    stop/0,
    start_projection/3,
    stop_projection/1,
    lookup/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    pids = #{} :: #{atom() => pid()},
    monitors = #{} :: #{reference() => atom()}
}).

-opaque state() :: #state{}.
-export_type([state/0]).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec stop() -> ok.
stop() ->
    gen_server:stop(?MODULE).

-spec start_projection(StoreContext, ProjectionModule, Options) ->
    {ok, pid()} | {error, Reason}
when
    StoreContext :: es_kernel_store:store_context(),
    ProjectionModule :: module(),
    Options :: es_projection:options(),
    Reason :: term().
start_projection(StoreContext, ProjectionModule, Options) ->
    gen_server:call(?MODULE, {start_projection, StoreContext, ProjectionModule, Options}).

-spec stop_projection(atom()) -> ok | {error, not_found}.
stop_projection(ProjectionName) ->
    gen_server:call(?MODULE, {stop_projection, ProjectionName}).

-spec lookup(atom()) -> {ok, pid()} | {error, not_found}.
lookup(ProjectionName) ->
    gen_server:call(?MODULE, {lookup, ProjectionName}).

-spec init([]) -> {ok, state()}.
init([]) ->
    {ok, #state{}}.

-spec handle_call(term(), {pid(), term()}, state()) ->
    {reply, term(), state()}.
handle_call({start_projection, StoreContext, ProjectionModule, Options}, _From, State) ->
    ProjectionName = ProjectionModule:name(),
    case maps:find(ProjectionName, State#state.pids) of
        {ok, Pid} ->
            {reply, {ok, Pid}, State};
        error ->
            start_and_monitor(ProjectionName, StoreContext, ProjectionModule, Options, State)
    end;
handle_call({stop_projection, ProjectionName}, _From, State) ->
    case maps:find(ProjectionName, State#state.pids) of
        {ok, Pid} ->
            ok = es_projection:stop(Pid),
            {reply, ok, remove_projection(ProjectionName, State)};
        error ->
            {reply, {error, not_found}, State}
    end;
handle_call({lookup, ProjectionName}, _From, State) ->
    case maps:find(ProjectionName, State#state.pids) of
        {ok, Pid} ->
            {reply, {ok, Pid}, State};
        error ->
            {reply, {error, not_found}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({'DOWN', MonitorRef, process, _Pid, _Reason}, State) ->
    case maps:find(MonitorRef, State#state.monitors) of
        {ok, ProjectionName} ->
            {noreply, remove_projection(ProjectionName, State)};
        error ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) ->
    ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-spec start_and_monitor(
    atom(), es_kernel_store:store_context(), module(), es_projection:options(), state()
) ->
    {reply, {ok, pid()} | {error, term()}, state()}.
start_and_monitor(ProjectionName, StoreContext, ProjectionModule, Options, State) ->
    case es_projection_sup:start_projection(StoreContext, ProjectionModule, Options) of
        {ok, Pid} ->
            MonitorRef = erlang:monitor(process, Pid),
            NewState = State#state{
                pids = (State#state.pids)#{ProjectionName => Pid},
                monitors = (State#state.monitors)#{MonitorRef => ProjectionName}
            },
            {reply, {ok, Pid}, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

-spec remove_projection(atom(), state()) -> state().
remove_projection(ProjectionName, State) ->
    Pids = maps:remove(ProjectionName, State#state.pids),
    Monitors = maps:filter(
        fun(_MonitorRef, Name) -> Name =/= ProjectionName end,
        State#state.monitors
    ),
    State#state{pids = Pids, monitors = Monitors}.
