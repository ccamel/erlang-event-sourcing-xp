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
    fold_all/3,
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
-define(POSITION_COUNTER_FILE, "position_counter").
-define(GLOBAL_INDEX_FILE, "global_index.dat").

-spec start() -> ok.
start() ->
    ok = ensure_dir(events_dir()),
    ok = ensure_dir(snapshots_dir()),
    ok = ensure_position_counter().

-spec stop() -> ok.
stop() ->
    ok.

-spec append(StreamId, Events) -> ok | {error, Reason} when
    StreamId :: stream_id(),
    Events :: [event()],
    Reason :: term().
append(_StreamId, []) ->
    ok;
append(StreamId, [#{aggregate_type := AggregateType} | _] = Events) ->
    BaseName = stream_basename(AggregateType, StreamId),
    Path = event_file_path(BaseName),
    ensure_dir(events_dir()),
    case ensure_unique(Path, Events) of
        ok ->
            case persist_events(Path, Events) of
                ok ->
                    NumEvents = length(Events),
                    StartPosition = allocate_positions(NumEvents),
                    EventsWithPositions = lists:zip(
                        Events, lists:seq(StartPosition, StartPosition + NumEvents - 1)
                    ),
                    append_to_global_index(EventsWithPositions, Path);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec fold(StreamId, Fun, Acc0, Range) -> {ok, Acc1} | {error, Reason} when
    StreamId :: stream_id(),
    Fun :: fun(
        (
            Event :: event(),
            Sequence :: sequence(),
            AccIn
        ) -> AccOut
    ),
    Acc0 :: term(),
    Range :: es_contract_range:range(),
    Acc1 :: term(),
    AccIn :: term(),
    AccOut :: term(),
    Reason :: term().
fold(StreamId, FoldFun, InitialAcc, Range) when
    is_function(FoldFun, 3)
->
    From = es_contract_range:lower_bound(Range),
    To = es_contract_range:upper_bound(Range),
    case read_events_for_stream(StreamId) of
        {ok, Events} ->
            Filtered = [
                E
             || E <- Events,
                #{sequence := Seq} <- [E],
                within_range(Seq, From, To)
            ],
            Result = lists:foldl(
                fun(#{sequence := Seq} = Event, Acc) -> FoldFun(Event, Seq, Acc) end,
                InitialAcc,
                Filtered
            ),
            {ok, Result};
        {error, not_found} ->
            {ok, InitialAcc};
        {error, Reason} ->
            {error, Reason}
    end.

-spec ensure_unique(file:filename(), [event()]) -> ok | {error, term()}.
ensure_unique(Path, Events) ->
    case read_terms(Path) of
        {ok, Existing} ->
            ExistingIds = sets:from_list([es_contract_event:key(E) || E <- Existing]),
            case
                lists:any(
                    fun(E) -> sets:is_element(es_contract_event:key(E), ExistingIds) end, Events
                )
            of
                true ->
                    {error, duplicate_event};
                false ->
                    ok
            end;
        {error, not_found} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

-spec persist_events(file:filename(), [event()]) -> ok | {error, term()}.
persist_events(Path, Events) ->
    IoData = [serialize_to_line(E) || E <- Events],
    case file:write_file(Path, IoData, [append]) of
        ok ->
            ok;
        {error, Reason} ->
            {error, Reason}
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
store(#{aggregate_type := AggregateType, stream_id := StreamId} = Snapshot) ->
    try
        BaseName = stream_basename(AggregateType, StreamId),
        Path = snapshot_file_path(BaseName),
        ensure_dir(snapshots_dir()),
        case file:write_file(Path, serialize_to_line(Snapshot), []) of
            ok -> ok;
            {error, Error} -> {warning, {write_error, Error}}
        end
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

%% Position counter and global index management

-spec ensure_position_counter() -> ok.
ensure_position_counter() ->
    Path = position_counter_path(),
    case filelib:is_file(Path) of
        true ->
            ok;
        false ->
            ensure_dir(root_dir()),
            file:write_file(Path, term_to_binary(0))
    end.

-spec allocate_positions(non_neg_integer()) -> es_contract_event_store:position().
allocate_positions(NumEvents) ->
    Path = position_counter_path(),
    {ok, Binary} = file:read_file(Path),
    CurrentPosition = binary_to_term(Binary),
    NewPosition = CurrentPosition + NumEvents,
    ok = file:write_file(Path, term_to_binary(NewPosition)),
    CurrentPosition.

-spec append_to_global_index([{event(), es_contract_event_store:position()}], file:filename()) ->
    ok | {error, term()}.
append_to_global_index(EventsWithPositions, EventFilePath) ->
    IndexPath = global_index_path(),
    IndexEntries = [
        {Position, EventFilePath, es_contract_event:key(Event)}
     || {Event, Position} <- EventsWithPositions
    ],
    IoData = [io_lib:format("~0p.~n", [Entry]) || Entry <- IndexEntries],
    case file:write_file(IndexPath, IoData, [append]) of
        ok ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

-spec fold_all(Fun, Acc0, Range) -> {ok, Acc1} | {error, Reason} when
    Fun :: fun((Event :: event(), Position :: es_contract_event_store:position(), AccIn) -> AccOut),
    Acc0 :: term(),
    Range :: es_contract_range:range(),
    Acc1 :: term(),
    AccIn :: term(),
    AccOut :: term(),
    Reason :: term().
fold_all(FoldFun, InitialAcc, Range) when is_function(FoldFun, 3) ->
    From = es_contract_range:lower_bound(Range),
    To = es_contract_range:upper_bound(Range),
    IndexPath = global_index_path(),
    case file:consult(IndexPath) of
        {ok, IndexEntries} ->
            %% Filter by position range
            Filtered = [
                {Position, FilePath, Key}
             || {Position, FilePath, Key} <- IndexEntries,
                within_range(Position, From, To)
            ],
            Sorted = lists:sort(fun({P1, _, _}, {P2, _, _}) -> P1 =< P2 end, Filtered),
            fold_global_entries(Sorted, FoldFun, InitialAcc);
        {error, enoent} ->
            {ok, InitialAcc};
        {error, Reason} ->
            {error, Reason}
    end.

-spec fold_global_entries(
    [{es_contract_event_store:position(), file:filename(), es_contract_event:key()}],
    fun((event(), es_contract_event_store:position(), AccIn) -> AccOut),
    AccIn
) ->
    {ok, AccOut} | {error, term()}
when
    AccIn :: term(),
    AccOut :: term().
fold_global_entries([], _FoldFun, Acc) ->
    {ok, Acc};
fold_global_entries([{Position, FilePath, Key} | Rest], FoldFun, Acc) ->
    case load_event_by_key(FilePath, Key) of
        {ok, Event} ->
            fold_global_entries(Rest, FoldFun, FoldFun(Event, Position, Acc));
        {error, Reason} ->
            {error, {missing_global_index_event, Position, FilePath, Key, Reason}}
    end.

-spec load_event_by_key(file:filename(), es_contract_event:key()) ->
    {ok, event()} | {error, not_found}.
load_event_by_key(FilePath, Key) ->
    case read_terms(FilePath) of
        {ok, Events} ->
            case lists:search(fun(E) -> es_contract_event:key(E) =:= Key end, Events) of
                {value, Event} ->
                    {ok, Event};
                false ->
                    {error, not_found}
            end;
        {error, _} ->
            {error, not_found}
    end.

-spec position_counter_path() -> file:filename().
position_counter_path() ->
    filename:join(root_dir(), ?POSITION_COUNTER_FILE).

-spec global_index_path() -> file:filename().
global_index_path() ->
    filename:join(root_dir(), ?GLOBAL_INDEX_FILE).
