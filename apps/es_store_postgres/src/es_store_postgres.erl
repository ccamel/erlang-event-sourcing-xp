-module(es_store_postgres).

-moduledoc """
PostgreSQL implementation of the event and snapshot store contracts.

Events and snapshots are stored as compressed Erlang external terms. PostgreSQL
owns the durable global event position through an identity column; stream-local
sequence numbers and global positions are both ordered by SQL queries.
""".

-behaviour(es_contract_event_store).
-behaviour(es_contract_snapshot_store).
-behaviour(gen_server).

-export([start/0, stop/0, start_link/0, append/2, fold/4, fold_all/3, store/1, load_latest/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-type stream_id() :: es_contract_event:stream_id().
-type sequence() :: es_contract_event:sequence().
-type event() :: es_contract_event:t().
-type snapshot() :: es_contract_snapshot:t().
-type state() :: #{connection := pid() | undefined}.

-define(APP, es_store_postgres).
-define(SERVER, ?MODULE).
-define(INSERT_EVENT_SQL,
    "INSERT INTO es_events (aggregate_type, event_type, occurred_at, stream_id, sequence, event) "
    "VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (stream_id, sequence) DO NOTHING"
).
-define(UPSERT_SNAPSHOT_SQL,
    "INSERT INTO es_snapshots (stream_id, sequence, snapshot) VALUES ($1, $2, $3) "
    "ON CONFLICT (stream_id) DO UPDATE SET sequence = EXCLUDED.sequence, "
    "snapshot = EXCLUDED.snapshot WHERE es_snapshots.sequence <= EXCLUDED.sequence"
).

-spec start() -> ok | {error, {atom(), term()}}.
start() ->
    case application:ensure_all_started(?APP) of
        {ok, _Started} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

-spec stop() -> ok.
stop() ->
    case erlang:whereis(?SERVER) of
        undefined ->
            ok;
        Pid ->
            gen_server:stop(Pid)
    end.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec append(stream_id(), [event()]) -> ok | {error, term()}.
append(_StreamId, []) ->
    ok;
append(StreamId, Events) ->
    gen_server:call(?SERVER, {append, StreamId, Events}, infinity).

-spec fold(
    stream_id(), fun((event(), sequence(), AccIn) -> AccOut), Acc0, es_contract_range:range()
) ->
    {ok, AccOut} | {error, term()}
when
    AccIn :: term(),
    AccOut :: term(),
    Acc0 :: AccIn.
fold(StreamId, FoldFun, Acc0, Range) when is_function(FoldFun, 3) ->
    gen_server:call(?SERVER, {fold, StreamId, FoldFun, Acc0, Range}, infinity).

-spec fold_all(
    fun((event(), es_contract_event_store:position(), AccIn) -> AccOut),
    Acc0,
    es_contract_range:range()
) -> {ok, AccOut} | {error, term()} when
    AccIn :: term(),
    AccOut :: term(),
    Acc0 :: AccIn.
fold_all(FoldFun, Acc0, Range) when is_function(FoldFun, 3) ->
    gen_server:call(?SERVER, {fold_all, FoldFun, Acc0, Range}, infinity).

-spec store(snapshot()) -> ok | {warning, term()}.
store(Snapshot) ->
    gen_server:call(?SERVER, {store, Snapshot}, infinity).

-spec load_latest(stream_id()) -> {ok, snapshot()} | {error, not_found}.
load_latest(StreamId) ->
    gen_server:call(?SERVER, {load_latest, StreamId}, infinity).

-spec init([]) -> {ok, #{connection := undefined}}.
init([]) ->
    {ok, #{connection => undefined}}.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call(Request, _From, State0) ->
    case ensure_connection(State0) of
        {ok, Connection, State} ->
            {reply, execute_request(Request, Connection), State};
        {error, Reason, State} ->
            {reply, request_error(Request, Reason), State}
    end.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Request, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, #{connection := undefined}) ->
    ok;
terminate(_Reason, #{connection := Connection}) ->
    close_connection(Connection).

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-spec ensure_connection(state()) -> {ok, pid(), state()} | {error, term(), state()}.
ensure_connection(#{connection := undefined} = State) ->
    case connect() of
        {ok, Connection} ->
            case ensure_schema(Connection) of
                ok ->
                    {ok, Connection, State#{connection := Connection}};
                {error, Reason} ->
                    close_connection(Connection),
                    {error, Reason, State}
            end;
        {error, Reason} ->
            {error, Reason, State}
    end;
ensure_connection(#{connection := Connection} = State) ->
    {ok, Connection, State}.

connect() ->
    epgsql:connect(connection_options()).

-spec close_connection(pid()) -> ok.
close_connection(Connection) ->
    try epgsql:close(Connection) of
        _ ->
            ok
    catch
        _:_ ->
            ok
    end.

connection_options() ->
    [
        {host, config(host, "ES_POSTGRES_HOST", "127.0.0.1")},
        {port, config_port()},
        {database, config(database, "ES_POSTGRES_DATABASE", "es_xp")},
        {username, config(username, "ES_POSTGRES_USERNAME", "es_xp")},
        {password, config(password, "ES_POSTGRES_PASSWORD", "es_xp")}
    ].

config(Key, EnvironmentKey, Default) ->
    case application:get_env(?APP, Key) of
        {ok, Value} ->
            to_string(Value);
        undefined ->
            case os:getenv(EnvironmentKey) of
                false -> Default;
                Value -> Value
            end
    end.

-spec config_port() -> inet:port_number().
config_port() ->
    case application:get_env(?APP, port) of
        {ok, Value} when is_integer(Value), Value > 0, Value =< 65535 ->
            Value;
        {ok, Value} ->
            parse_port(to_string(Value));
        undefined ->
            parse_port(config(port, "ES_POSTGRES_PORT", "5432"))
    end.

-spec parse_port(string()) -> inet:port_number().
parse_port(Value) ->
    case string:to_integer(Value) of
        {Port, []} when Port > 0, Port =< 65535 ->
            Port;
        _ ->
            error({invalid_postgres_port, Value})
    end.

-spec to_string(string() | binary() | atom()) -> string().
to_string(Value) when is_list(Value) ->
    Value;
to_string(Value) when is_binary(Value) ->
    binary_to_list(Value);
to_string(Value) when is_atom(Value) ->
    atom_to_list(Value).

ensure_schema(Connection) ->
    execute_statements(Connection, [
        "CREATE TABLE IF NOT EXISTS es_events ("
        "aggregate_type TEXT NOT NULL, "
        "event_type BYTEA NOT NULL, "
        "occurred_at BIGINT, "
        "stream_id BYTEA NOT NULL, "
        "sequence BIGINT NOT NULL CHECK (sequence >= 0), "
        "position BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, "
        "event BYTEA NOT NULL, "
        "UNIQUE (stream_id, sequence))",
        "CREATE INDEX IF NOT EXISTS es_events_type_position_idx "
        "ON es_events (aggregate_type, event_type, position)",
        "CREATE INDEX IF NOT EXISTS es_events_type_occurred_at_position_idx "
        "ON es_events (aggregate_type, occurred_at, position) WHERE occurred_at IS NOT NULL",
        "CREATE TABLE IF NOT EXISTS es_snapshots ("
        "stream_id BYTEA PRIMARY KEY, "
        "sequence BIGINT NOT NULL CHECK (sequence >= 0), "
        "snapshot BYTEA NOT NULL)"
    ]).

execute_statements(_Connection, []) ->
    ok;
execute_statements(Connection, [Statement | Rest]) ->
    case epgsql:equery(Connection, Statement) of
        {ok, _Count} ->
            execute_statements(Connection, Rest);
        {ok, _Columns, []} ->
            execute_statements(Connection, Rest);
        {error, Reason} ->
            {error, Reason}
    end.

execute_request({append, _StreamId, Events}, Connection) ->
    append_events(Connection, Events);
execute_request({fold, StreamId, FoldFun, Acc0, Range}, Connection) ->
    fold_stream(Connection, StreamId, FoldFun, Acc0, Range);
execute_request({fold_all, FoldFun, Acc0, Range}, Connection) ->
    fold_global(Connection, FoldFun, Acc0, Range);
execute_request({store, Snapshot}, Connection) ->
    store_snapshot(Connection, Snapshot);
execute_request({load_latest, StreamId}, Connection) ->
    load_snapshot(Connection, StreamId).

request_error({store, _Snapshot}, Reason) ->
    {warning, Reason};
request_error(_Request, Reason) ->
    {error, Reason}.

-spec append_events(pid(), [event()]) -> ok | {error, term()}.
append_events(Connection, Events) ->
    try
        epgsql:with_transaction(Connection, fun(TransactionConnection) ->
            insert_events(TransactionConnection, Events)
        end)
    of
        ok ->
            ok;
        {rollback, duplicate_event} ->
            {error, duplicate_event};
        {rollback, Reason} ->
            {error, Reason}
    catch
        Class:Reason ->
            {error, {Class, Reason}}
    end.

-spec insert_events(pid(), [event()]) -> ok.
insert_events(_Connection, []) ->
    ok;
insert_events(
    Connection,
    [
        #{
            aggregate_type := AggregateType,
            type := EventType,
            stream_id := StreamId,
            sequence := Sequence,
            metadata := Metadata
        } = Event
        | Rest
    ]
) ->
    case
        epgsql:equery(Connection, ?INSERT_EVENT_SQL, [
            atom_to_binary(AggregateType, utf8),
            type_to_binary(EventType),
            maps:get(timestamp, Metadata, null),
            encode(StreamId),
            Sequence,
            encode(Event)
        ])
    of
        {ok, 1} ->
            insert_events(Connection, Rest);
        {ok, 0} ->
            error(duplicate_event);
        {error, Reason} ->
            error({insert_failed, Reason})
    end.

-spec type_to_binary(es_contract_event:type()) -> binary().
type_to_binary(Type) when is_atom(Type) ->
    atom_to_binary(Type, utf8);
type_to_binary(Type) when is_binary(Type) ->
    Type.
-spec fold_stream(
    pid(), stream_id(), fun((event(), sequence(), AccIn) -> AccOut), Acc0, es_contract_range:range()
) -> {ok, AccOut} | {error, term()} when
    AccIn :: term(),
    AccOut :: term(),
    Acc0 :: AccIn.
fold_stream(Connection, StreamId, FoldFun, Acc0, Range) ->
    {Sql, Params} = stream_query(StreamId, Range),
    case epgsql:equery(Connection, Sql, Params) of
        {ok, _Columns, Rows} ->
            fold_stream_rows(Rows, FoldFun, Acc0);
        {error, Reason} ->
            {error, Reason}
    end.

-spec stream_query(stream_id(), es_contract_range:range()) -> {iodata(), [term()]}.
stream_query(StreamId, Range) ->
    From = es_contract_range:lower_bound(Range),
    case es_contract_range:upper_bound(Range) of
        infinity ->
            {
                "SELECT sequence, event FROM es_events "
                "WHERE stream_id = $1 AND sequence >= $2 ORDER BY sequence",
                [encode(StreamId), From]
            };
        To ->
            {
                "SELECT sequence, event FROM es_events "
                "WHERE stream_id = $1 AND sequence >= $2 AND sequence < $3 ORDER BY sequence",
                [encode(StreamId), From, To]
            }
    end.

-spec fold_stream_rows([tuple()], fun((event(), sequence(), AccIn) -> AccOut), Acc0) ->
    {ok, AccOut} | {error, term()}
when
    AccIn :: term(),
    AccOut :: term(),
    Acc0 :: AccIn.
fold_stream_rows(Rows, FoldFun, Acc0) ->
    try
        {ok,
            lists:foldl(
                fun({Sequence, EncodedEvent}, Acc) ->
                    FoldFun(decode(EncodedEvent), Sequence, Acc)
                end,
                Acc0,
                Rows
            )}
    catch
        Class:Reason ->
            {error, {Class, Reason}}
    end.

-spec fold_global(
    pid(),
    fun((event(), es_contract_event_store:position(), AccIn) -> AccOut),
    Acc0,
    es_contract_range:range()
) -> {ok, AccOut} | {error, term()} when
    AccIn :: term(),
    AccOut :: term(),
    Acc0 :: AccIn.
fold_global(Connection, FoldFun, Acc0, Range) ->
    {Sql, Params} = global_query(Range),
    case epgsql:equery(Connection, Sql, Params) of
        {ok, _Columns, Rows} ->
            fold_global_rows(Rows, FoldFun, Acc0);
        {error, Reason} ->
            {error, Reason}
    end.

global_query(Range) ->
    From = es_contract_range:lower_bound(Range),
    case es_contract_range:upper_bound(Range) of
        infinity ->
            {
                "SELECT position, event FROM es_events WHERE position >= $1 ORDER BY position",
                [From]
            };
        To ->
            {
                "SELECT position, event FROM es_events "
                "WHERE position >= $1 AND position < $2 ORDER BY position",
                [From, To]
            }
    end.

-spec fold_global_rows(
    [tuple()], fun((event(), es_contract_event_store:position(), AccIn) -> AccOut), Acc0
) -> {ok, AccOut} | {error, term()} when
    AccIn :: term(),
    AccOut :: term(),
    Acc0 :: AccIn.
fold_global_rows(Rows, FoldFun, Acc0) ->
    try
        {ok,
            lists:foldl(
                fun({Position, EncodedEvent}, Acc) ->
                    FoldFun(decode(EncodedEvent), Position, Acc)
                end,
                Acc0,
                Rows
            )}
    catch
        Class:Reason ->
            {error, {Class, Reason}}
    end.

-spec store_snapshot(pid(), snapshot()) -> ok | {warning, term()}.
store_snapshot(Connection, #{stream_id := StreamId, sequence := Sequence} = Snapshot) ->
    case
        epgsql:equery(Connection, ?UPSERT_SNAPSHOT_SQL, [
            encode(StreamId), Sequence, encode(Snapshot)
        ])
    of
        {ok, _Count} ->
            ok;
        {error, Reason} ->
            {warning, Reason}
    end.

-spec load_snapshot(pid(), stream_id()) -> {ok, snapshot()} | {error, not_found}.
load_snapshot(Connection, StreamId) ->
    case
        epgsql:equery(
            Connection,
            "SELECT snapshot FROM es_snapshots WHERE stream_id = $1",
            [encode(StreamId)]
        )
    of
        {ok, _Columns, [{EncodedSnapshot}]} ->
            try
                {ok, decode(EncodedSnapshot)}
            catch
                Class:Reason ->
                    error({snapshot_decode_failed, {Class, Reason}})
            end;
        {ok, _Columns, []} ->
            {error, not_found};
        {error, Reason} ->
            error({snapshot_load_failed, Reason})
    end.

-spec encode(term()) -> binary().
encode(Term) ->
    term_to_binary(Term, [compressed]).

-spec decode(binary()) -> term().
decode(Binary) ->
    binary_to_term(Binary, [safe]).
