-module(es_projection_checkpoint_ets).

-moduledoc """
ETS-backed projection checkpoint store.

This backend is explicitly ephemeral: its checkpoints are lost when the VM
restarts. Use it for tests or deployments that do not require recovery across a
VM restart; configure a durable checkpoint backend when recovery is required.

The table is owned by a dedicated process, never a projection runner, so it
survives direct-runner restarts within the VM.
""".

-behaviour(es_contract_projection_checkpoint_store).
-behaviour(gen_server).

-export([
    start/0,
    start_link/0,
    stop/0,
    load_checkpoint/1,
    store_checkpoint/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(DEFAULT_TABLE_NAME, projection_checkpoints).

-spec start() -> ok | {error, term()}.
start() ->
    case ensure_owner_started() of
        ok ->
            gen_server:call(?MODULE, {ensure_table, table_name()});
        {error, Reason} ->
            {error, Reason}
    end.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    case erlang:whereis(?MODULE) of
        undefined ->
            gen_server:start_link({local, ?MODULE}, ?MODULE, [], []);
        Pid ->
            erlang:link(Pid),
            {ok, Pid}
    end.

-spec stop() -> ok.
stop() ->
    case erlang:whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            gen_server:stop(?MODULE)
    end.

-spec load_checkpoint(ProjectionName) -> {ok, Position} | {error, not_found} when
    ProjectionName :: atom(),
    Position :: es_contract_event_store:position().
load_checkpoint(ProjectionName) ->
    case ets:lookup(table_name(), ProjectionName) of
        [{ProjectionName, Position}] ->
            {ok, Position};
        [] ->
            {error, not_found}
    end.

-spec store_checkpoint(ProjectionName, Position) -> ok when
    ProjectionName :: atom(),
    Position :: es_contract_event_store:position().
store_checkpoint(ProjectionName, Position) ->
    true = ets:insert(table_name(), {ProjectionName, Position}),
    ok.

-spec init([]) -> {ok, #{}} | {stop, invalid_table_name}.
init([]) ->
    case create_table(table_name()) of
        ok ->
            {ok, #{}};
        {error, invalid_table_name} ->
            {stop, invalid_table_name}
    end.

-spec handle_call(term(), gen_server:from(), #{}) ->
    {reply, ok | {error, invalid_table_name}, #{}}.
handle_call({ensure_table, Table}, _From, State) ->
    {reply, create_table(Table), State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(term(), #{}) -> {noreply, #{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(term(), #{}) -> {noreply, #{}}.
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), #{}) -> ok.
terminate(_Reason, _State) ->
    ok.

-spec code_change(term(), #{}, term()) -> {ok, #{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-spec ensure_owner_started() -> ok | {error, term()}.
ensure_owner_started() ->
    case gen_server:start({local, ?MODULE}, ?MODULE, [], []) of
        {ok, _Pid} ->
            ok;
        {error, {already_started, _Pid}} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

-spec table_name() -> atom().
table_name() ->
    application:get_env(es_projection, projection_checkpoint_table_name, ?DEFAULT_TABLE_NAME).

-spec create_table(term()) -> ok | {error, invalid_table_name}.
create_table(Table) when is_atom(Table) ->
    try
        _ = ets:new(Table, [set, named_table, public]),
        ok
    catch
        error:badarg ->
            case ets:info(Table) of
                undefined ->
                    {error, invalid_table_name};
                _ ->
                    ok
            end
    end;
create_table(_) ->
    {error, invalid_table_name}.
