-module(es_store_file).
-moduledoc """
Pedagogical file-based implementation of the event and snapshot store.

Events and snapshots are serialized as Erlang terms, one per line, under a
configurable root directory.
""".

-behaviour(es_contract_event_store).
-behaviour(es_contract_snapshot_store).

-export([
    start/0,
    stop/0,
    fold/4,
    append/2,
    store/1,
    load_latest/1
]).

-export_type([
    event/0, stream_id/0, sequence/0, timestamp/0, snapshot/0, snapshot_data/0
]).

-type stream_id() :: es_contract_event:stream_id().
-type sequence() :: es_contract_event:sequence().
-type timestamp() :: non_neg_integer().
-type event() :: es_contract_event:t().
-type snapshot() :: es_contract_snapshot:t().
-type snapshot_data() :: es_contract_snapshot:state().

-define(DEFAULT_ROOT_DIR, "./data/store").
-define(EVENTS_SUBDIR, "events").
-define(SNAPSHOTS_SUBDIR, "snapshots").
-define(EVENT_EXT, ".log").
-define(SNAPSHOT_EXT, ".snap").

-spec start() -> ok.
start() ->
    ok = ensure_dir(events_dir()),
    ok = ensure_dir(snapshots_dir()).

-spec stop() -> ok.
stop() ->
    ok.

-spec append(StreamId, Events) -> ok when
    StreamId :: stream_id(),
    Events :: [event()].
append(_StreamId, []) ->
    ok;
append(StreamId, [First | _] = Events) ->
    BaseName = stream_basename(es_kernel_store:domain(First), StreamId),
    Path = event_file_path(BaseName),
    ensure_dir(events_dir()),
    ensure_unique(Path, Events),
    persist_events(Path, Events).

-spec fold(StreamId, Fun, Acc0, Range) -> Acc1 when
    StreamId :: stream_id(),
    Fun :: fun((Event :: event(), AccIn) -> AccOut),
    Acc0 :: term(),
    Range :: es_contract_range:range(),
    Acc1 :: term(),
    AccIn :: term(),
    AccOut :: term().
fold(StreamId, FoldFun, InitialAcc, Range) when
    is_function(FoldFun, 2)
->
    From = es_contract_range:lower_bound(Range),
    To = es_contract_range:upper_bound(Range),
    case read_events_for_stream(StreamId) of
        {ok, Events} ->
            Filtered = [
                E
             || E <- Events,
                within_range(es_kernel_store:sequence(E), From, To)
            ],
            lists:foldl(FoldFun, InitialAcc, Filtered);
        {error, not_found} ->
            InitialAcc;
        {error, Reason} ->
            erlang:error(Reason)
    end.

-spec ensure_unique(file:filename(), [event()]) -> ok.
ensure_unique(Path, Events) ->
    case read_terms(Path) of
        {ok, Existing} ->
            ExistingIds = sets:from_list([es_kernel_store:id(E) || E <- Existing]),
            case
                lists:any(fun(E) -> sets:is_element(es_kernel_store:id(E), ExistingIds) end, Events)
            of
                true ->
                    erlang:error(duplicate_event);
                false ->
                    ok
            end;
        {error, not_found} ->
            ok;
        {error, Reason} ->
            erlang:error(Reason)
    end.

-spec persist_events(file:filename(), [event()]) -> ok.
persist_events(Path, Events) ->
    IoData = [serialize_to_line(E) || E <- Events],
    case file:write_file(Path, IoData, [append]) of
        ok ->
            ok;
        {error, Reason} ->
            erlang:error(Reason)
    end.

-spec serialize_to_line(event() | snapshot()) -> iolist().
serialize_to_line(Term) ->
    [io_lib:format("~0p", [Term]), ".\n"].

-spec within_range(sequence(), sequence() | 0, sequence() | infinity) -> boolean().
within_range(Seq, From, infinity) ->
    Seq >= From;
within_range(Seq, From, To) ->
    Seq >= From andalso Seq < To.

-spec read_events_for_stream(stream_id()) -> {ok, [event()]} | {error, not_found | term()}.
read_events_for_stream(StreamId) ->
    case locate_event_file(StreamId) of
        {ok, Path} ->
            read_terms(Path);
        {error, Reason} ->
            {error, Reason}
    end.

-spec store(Snapshot) -> ok | {warning, Reason} when
    Snapshot :: snapshot(),
    Reason :: term().
store(Snapshot) ->
    try
        BaseName = stream_basename(
            es_kernel_store:snapshot_domain(Snapshot),
            es_kernel_store:snapshot_stream_id(Snapshot)
        ),
        Path = snapshot_file_path(BaseName),
        ensure_dir(snapshots_dir()),
        file:write_file(Path, serialize_to_line(Snapshot), [])
    catch
        Class:Reason ->
            {warning, {Class, Reason}}
    end.

-spec load_latest(StreamId) -> {ok, Snapshot} | {error, not_found} when
    StreamId :: stream_id(),
    Snapshot :: snapshot().
load_latest(StreamId) ->
    case locate_snapshot_file(StreamId) of
        {ok, Path} ->
            case read_terms(Path) of
                {ok, []} ->
                    {error, not_found};
                {ok, Terms} ->
                    {ok, lists:last(Terms)};
                {error, Reason} ->
                    erlang:error(Reason)
            end;
        {error, not_found} ->
            {error, not_found};
        {error, Reason} ->
            erlang:error(Reason)
    end.

-spec read_terms(string()) ->
    {ok, [event() | snapshot()]} | {error, atom() | {integer(), atom(), term()}}.
read_terms(Path) ->
    case file:consult(Path) of
        {ok, Terms} ->
            {ok, Terms};
        {error, enoent} ->
            {error, not_found};
        {error, Reason} ->
            {error, Reason}
    end.

-spec locate_event_file(stream_id()) -> {ok, file:filename()} | {error, term()}.
locate_event_file(StreamId) ->
    locate_stream_file(events_dir(), sanitize(StreamId), ?EVENT_EXT).

-spec locate_snapshot_file(stream_id()) -> {ok, file:filename()} | {error, term()}.
locate_snapshot_file(StreamId) ->
    locate_stream_file(snapshots_dir(), sanitize(StreamId), ?SNAPSHOT_EXT).

-spec locate_stream_file(string(), string(), string()) ->
    {ok, string()} | {error, not_found | {ambiguous_stream, [string()]}}.
locate_stream_file(Dir, Suffix, Ext) ->
    Pattern = filename:join(Dir, "*" ++ Suffix ++ Ext),
    case filelib:wildcard(Pattern) of
        [Path] ->
            {ok, Path};
        [] ->
            {error, not_found};
        Paths ->
            {error, {ambiguous_stream, Paths}}
    end.

-spec stream_basename(atom(), stream_id()) -> nonempty_string().
stream_basename(Domain, {_Domain, AggId}) ->
    sanitize(Domain) ++ "_" ++ sanitize(AggId).

-spec events_dir() -> file:filename().
events_dir() ->
    filename:join(root_dir(), ?EVENTS_SUBDIR).

-spec snapshots_dir() -> file:filename().
snapshots_dir() ->
    filename:join(root_dir(), ?SNAPSHOTS_SUBDIR).

-spec event_file_path(string()) -> file:filename().
event_file_path(BaseName) ->
    filename:join(events_dir(), BaseName ++ ?EVENT_EXT).

-spec snapshot_file_path(string()) -> file:filename().
snapshot_file_path(BaseName) ->
    filename:join(snapshots_dir(), BaseName ++ ?SNAPSHOT_EXT).

-spec root_dir() -> file:filename().
root_dir() ->
    to_string(application:get_env(es_store_file, root_dir, ?DEFAULT_ROOT_DIR)).

-spec ensure_dir(file:filename()) -> ok.
ensure_dir(Dir) ->
    filelib:ensure_dir(filename:join(Dir, ".keep")).

-spec sanitize(atom() | binary() | string() | stream_id()) -> string().
sanitize({Domain, AggId}) ->
    sanitize(Domain) ++ "_" ++ sanitize(AggId);
sanitize(Value) when is_atom(Value) ->
    sanitize_component(atom_to_list(Value));
sanitize(Value) when is_binary(Value) ->
    sanitize_component(binary_to_list(Value));
sanitize(Value) when is_list(Value) ->
    sanitize_component(Value).

-spec sanitize_component(string()) -> string().
sanitize_component(Value) ->
    lists:map(
        fun
            ($/) -> $_;
            ($\\) -> $_;
            ($:) -> $_;
            ($\n) -> $_;
            ($\r) -> $_;
            ($\t) -> $_;
            ($*) -> $_;
            ($?) -> $_;
            ($") -> $_;
            ($<) -> $_;
            ($>) -> $_;
            ($|) -> $_;
            ($\s) -> $_;
            (Char) -> Char
        end,
        Value
    ).

-spec to_string(list() | binary() | atom()) -> string().
to_string(Value) when is_list(Value) ->
    Value;
to_string(Value) when is_binary(Value) ->
    binary_to_list(Value);
to_string(Value) when is_atom(Value) ->
    atom_to_list(Value).
