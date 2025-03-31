-module(event_sourcing_core_mgr_aggregate).
-moduledoc """
This module implements a `gen_server` that manages event-sourcing aggregates.

It acts as a router and supervisor for aggregate processes, dispatching commands
to the appropriate aggregate instance based on a stream ID. It ensures that each
stream ID maps to a single aggregate process, starting new ones as needed and
monitoring them for crashes.
""".

-behaviour(gen_server).

-include_lib("event_sourcing_core.hrl").

-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2, start_link/4,
         start_link/3, stop/1, dispatch/2]).

-export_type([command/0, state/0, sequence/0, timestamp/0]).

-record(state,
        {aggregate :: module(),
         store :: module(),
         router :: module(),
         opts ::
             #{timeout => timeout(),
               sequence_zero => fun(() -> sequence()),
               sequence_next => fun((sequence()) -> sequence()),
               now_fun => fun(() -> timestamp())},
         pids :: #{stream_id() => pid()}}).

-opaque state() :: #state{}.

-doc """
Starts the aggregate manager with custom options.

- Aggregate is he module implementing the aggregate logic.
- Store is the module implementing the event store.
- Router is the module extracting routing info from commands.
- Opts is the configuration options:
  - `timeout`: Timeout for operations (default: `infinity`).
  - `sequence_zero`: Function to initialize sequence (default: returns 0).
  - `sequence_next`: Function to increment sequence (default: adds 1).
  - `now_fun`: Function to get current timestamp (default: system time).

Function returns `{ok, Pid}` on success, or an error tuple if the server fails to start.
""".
-spec start_link(Aggregate, Store, Router, Opts) -> gen_server:start_ret()
    when Aggregate :: module(),
         Store :: module(),
         Router :: module(),
         Opts ::
             #{timeout => timeout(),
               sequence_zero => fun(() -> sequence()),
               sequence_next => fun((sequence()) -> sequence()),
               now_fun => fun(() -> timestamp())}.
start_link(Aggregate, Store, Router, Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {Aggregate, Store, Router, Opts}, []).

-doc """
Starts the aggregate manager with the given aggregate, store, and router modules,
using default options.

- Aggregate is the module implementing the aggregate logic.
- Store is the module implementing the event store.
- Router is the module extracting routing info from commands.

Function returns `{ok, Pid}` on success, or an error tuple if the server fails to start.
""".
-spec start_link(Aggregate, Store, Router) -> gen_server:start_ret()
    when Aggregate :: module(),
         Store :: module(),
         Router :: module().
start_link(Aggregate, Store, Router) ->
    start_link(Aggregate, Store, Router, #{}).

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

Function returns `{ok, Result}` on success, or `{error, Reason}` if routing or execution fails.
""".
-spec dispatch(Pid, Command) -> {ok, Result} | {error, Reason}
    when Pid :: pid(),
         Command :: command(),
         Result :: term(),
         Reason :: term().
dispatch(Pid, Command) ->
    gen_server:call(Pid, Command).

-doc """
Initializes the aggregate manager state.

- Args is the tuple containing the aggregate, store, router modules, and options.

Function returns `{ok, State}` with an initialized state record.
""".
-spec init({Aggregate, Store, Router, Opts}) -> {ok, State}
    when Aggregate :: module(),
         Store :: module(),
         Router :: module(),
         Opts ::
             #{timeout => timeout(),
               sequence_zero => fun(() -> sequence()),
               sequence_next => fun((sequence()) -> sequence()),
               now_fun => fun(() -> timestamp())},
         State :: state().
init({Aggregate, Store, Router, Opts}) ->
    {ok,
     #state{aggregate = Aggregate,
            store = Store,
            router = Router,
            opts = Opts,
            pids = #{}}}.

-spec handle_call(Command, From, State) ->
                     {reply, ok, State} | {reply, {error, Reason}, State}
    when Command :: command(),
         From :: {pid(), term()},
         State :: state(),
         Reason :: term().
handle_call(Command, _From, #state{aggregate = Aggregate, router = Router} = State) ->
    case Router:extract_routing(Command) of
        {ok, {Aggregate, Id}} ->
            ensure_and_dispatch(Aggregate, Id, Command, State);
        {ok, {WrongAgg, _Id}} when WrongAgg =/= Aggregate ->
            {reply, {error, wrong_aggregate}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end.

-spec handle_cast(Command, State) -> {noreply, State}
    when Command :: command(),
         State :: state().
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec terminate(Reason, State) -> ok
    when Reason :: term(),
         State :: state().
terminate(_Reason, _State) ->
    ok.

-doc """
Handles process monitoring messages.

Removes the pid of a downed aggregate from the state's `pids` map.

- Info represents the `'DOWN'` message from a monitored process.

Function returns `{noreply, State}` with updated state.
""".
-spec handle_info(Info, State) -> {noreply, State}
    when Info :: {'DOWN', _Ref, process, Pid, _Reason},
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

Function returns `{reply, {ok, Result}, State}` or `{reply, {error, Reason}, State}`.
""".
-spec ensure_and_dispatch(Aggregate, Id, Command, State) -> {reply, Result, State}
    when Aggregate :: module(),
         Id :: stream_id(),
         Command :: command(),
         Result :: term(),
         State :: state().
ensure_and_dispatch(Aggregate,
                    Id,
                    Command,
                    #state{store = Store,
                           pids = Pids,
                           opts = Opts} =
                        State) ->
    case maps:get(Id, Pids, undefined) of
        undefined ->
            case start_aggregate(Aggregate, Store, Id, Opts) of
                {ok, Pid} ->
                    Result = forward(Pid, Command),
                    NewPids = maps:put(Id, Pid, Pids),
                    {reply, Result, State#state{pids = NewPids}};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        Pid ->
            Result = forward(Pid, Command),
            {reply, Result, State}
    end.

-doc """
Forwards a command to an aggregate process.

Function returns The result of the aggregate's dispatch function.
""".
-spec forward(Pid, Command) -> {ok, Result} | {error, Reason}
    when Pid :: pid(),
         Command :: command(),
         Result :: pid(),
         Reason :: term().
forward(Pid, Command) ->
    event_sourcing_core_aggregate:dispatch(Pid, Command).

-doc """
Starts an aggregate process for a given stream ID.

Monitors the new process and returns its pid.

Function returns `{ok, Pid}` on success, or `{error, Reason}` on failure.
""".
-spec start_aggregate(Aggregate, Store, Id, Opts) -> {ok, Result} | {error, Reason}
    when Aggregate :: module(),
         Store :: module(),
         Id :: stream_id(),
         Opts ::
             #{timeout => timeout(),
               sequence_zero => fun(() -> sequence()),
               sequence_next => fun((sequence()) -> sequence()),
               now_fun => fun(() -> timestamp())},
         Result :: pid(),
         Reason :: term().
start_aggregate(Aggregate, Store, Id, Opts) ->
    case event_sourcing_core_aggregate:start_link(Aggregate, Store, Id, Opts) of
        {ok, Pid} ->
            erlang:monitor(process, Pid),
            {ok, Pid};
        {error, Reason} ->
            {error, Reason}
    end.
