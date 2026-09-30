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
    append/3,
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

-type journal_entry() :: {es_contract_event_store:position(), event()}.

-define(DEFAULT_ROOT_DIR, "./data/store").
-define(EVENTS_SUBDIR, "events").
-define(SNAPSHOTS_SUBDIR, "snapshots").
-define(EVENT_EXT, ".log").
-define(SNAPSHOT_EXT, ".snap").
-define(JOURNAL_FILE, "event_log.dat").
-define(LEGACY_GLOBAL_INDEX_FILE, "global_index.dat").

-spec start() -> ok | {error, term()}.
start() ->
    case ensure_dir(events_dir()) of
        ok ->
            case ensure_dir(snapshots_dir()) of
                ok ->
                    global:trans(lock_id(), fun initialize_journal/0);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec stop() -> ok.
stop() ->
    ok.

-spec append(StreamId, ExpectedSequence, Events) ->
    {ok, NewSequence} | {error, Reason}
when
    StreamId :: stream_id(),
    ExpectedSequence :: sequence(),
    Events :: [event()],
    NewSequence :: sequence(),
    Reason :: term().
append(StreamId, ExpectedSequence, Events) ->
    case es_contract_event_store:validate_append(StreamId, ExpectedSequence, Events) of
        ok ->
            global:trans(
                lock_id(),
                fun() -> append_locked(StreamId, ExpectedSequence, Events) end
            );
        {error, Reason} ->
            {error, Reason}
    end.

-spec append_locked(stream_id(), sequence(), [event()]) ->
    {ok, sequence()} | {error, term()}.
append_locked(StreamId, ExpectedSequence, Events) ->
    case read_committed_entries() of
        {ok, Entries} ->
            ActualSequence = stream_sequence(StreamId, Entries),
            case ActualSequence =:= ExpectedSequence of
                true ->
                    append_entries(Entries, ExpectedSequence, Events);
                false ->
                    {error, {wrong_expected_sequence, ExpectedSequence, ActualSequence}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec append_entries([journal_entry()], sequence(), [event()]) ->
    {ok, sequence()} | {error, term()}.
append_entries(_Entries, ExpectedSequence, []) ->
    {ok, ExpectedSequence};
append_entries(Entries, ExpectedSequence, Events) ->
    NewEntries = Entries ++ events_with_positions(next_global_position(Entries), Events),
    case replace_journal(NewEntries) of
        ok ->
            {ok, ExpectedSequence + length(Events)};
        {error, Reason} ->
            {error, Reason}
    end.

-spec stream_sequence(stream_id(), [journal_entry()]) -> sequence().
stream_sequence(StreamId, Entries) ->
    lists:foldl(
        fun
            ({_, #{stream_id := EventStream, sequence := Sequence}}, ActualSequence) when
                EventStream =:= StreamId
            ->
                max(Sequence, ActualSequence);
            (_, ActualSequence) ->
                ActualSequence
        end,
        0,
        Entries
    ).

-spec events_with_positions(es_contract_event_store:position(), [event()]) -> [journal_entry()].
events_with_positions(Position, Events) ->
    events_with_positions(Position, Events, []).

-spec events_with_positions(es_contract_event_store:position(), [event()], [journal_entry()]) ->
    [journal_entry()].
events_with_positions(_Position, [], Acc) ->
    lists:reverse(Acc);
events_with_positions(Position, [Event | Rest], Acc) ->
    events_with_positions(Position + 1, Rest, [{Position, Event} | Acc]).

-spec next_global_position([journal_entry()]) -> es_contract_event_store:position().
next_global_position([]) ->
    0;
next_global_position(Entries) ->
    {Position, _} = lists:last(Entries),
    Position + 1.

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
fold(StreamId, FoldFun, InitialAcc, Range) when is_function(FoldFun, 3) ->
    From = es_contract_range:lower_bound(Range),
    To = es_contract_range:upper_bound(Range),
    case read_events_for_stream(StreamId) of
        {ok, Events} ->
            {ok, fold_stream_events(Events, FoldFun, InitialAcc, From, To)};
        {error, not_found} ->
            {ok, InitialAcc};
        {error, Reason} ->
            {error, Reason}
    end.

fold_stream_events([], _FoldFun, Acc, _From, _To) ->
    Acc;
fold_stream_events([#{sequence := Sequence} = Event | Rest], FoldFun, Acc, From, To) ->
    case within_range(Sequence, From, To) of
        true ->
            fold_stream_events(Rest, FoldFun, FoldFun(Event, Sequence, Acc), From, To);
        false ->
            fold_stream_events(Rest, FoldFun, Acc, From, To)
    end.

-spec serialize_to_line(journal_entry() | snapshot()) -> binary().
serialize_to_line(Term) ->
    unicode:characters_to_binary(io_lib:format("~0p.~n", [Term])).

-spec within_range(sequence(), sequence() | 0, sequence() | infinity) -> boolean().
within_range(Seq, From, infinity) ->
    Seq >= From;
within_range(Seq, From, To) ->
    Seq >= From andalso Seq < To.

-spec read_events_for_stream(stream_id()) -> {ok, [event()]} | {error, not_found | term()}.
read_events_for_stream(StreamId) ->
    case read_committed_entries() of
        {ok, Entries} ->
            {ok, stream_events(StreamId, Entries)};
        {error, Reason} ->
            {error, Reason}
    end.

-spec stream_events(stream_id(), [journal_entry()]) -> [event()].
stream_events(StreamId, Entries) ->
    lists:sort(
        fun(#{sequence := First}, #{sequence := Second}) -> First =< Second end,
        [
            Event
         || {_, #{stream_id := EventStreamId} = Event} <- Entries,
            EventStreamId =:= StreamId
        ]
    ).

-spec store(Snapshot) -> ok | {warning, Reason} when
    Snapshot :: snapshot(),
    Reason :: term().
store(#{aggregate_type := AggregateType, stream_id := StreamId} = Snapshot) ->
    try
        BaseName = stream_basename(AggregateType, StreamId),
        Path = snapshot_file_path(BaseName),
        ok = ensure_dir(snapshots_dir()),
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

-spec read_terms(file:filename()) -> {ok, [term()]} | {error, term()}.
read_terms(Path) ->
    case file:consult(Path) of
        {ok, Terms} ->
            {ok, Terms};
        {error, enoent} ->
            {error, not_found};
        {error, Reason} ->
            {error, Reason}
    end.

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

-spec snapshot_file_path(string()) -> file:filename().
snapshot_file_path(BaseName) ->
    filename:join(snapshots_dir(), BaseName ++ ?SNAPSHOT_EXT).

-spec root_dir() -> file:filename().
root_dir() ->
    to_string(application:get_env(es_store_file, root_dir, ?DEFAULT_ROOT_DIR)).

-spec ensure_dir(string()) -> ok | {error, atom()}.
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

%% Canonical event log

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
    case read_committed_entries() of
        {ok, Entries} ->
            {ok, fold_global_entries(Entries, FoldFun, InitialAcc, From, To)};
        {error, Reason} ->
            {error, Reason}
    end.

fold_global_entries([], _FoldFun, Acc, _From, _To) ->
    Acc;
fold_global_entries([{Position, Event} | Rest], FoldFun, Acc, From, To) ->
    case within_range(Position, From, To) of
        true ->
            fold_global_entries(Rest, FoldFun, FoldFun(Event, Position, Acc), From, To);
        false ->
            fold_global_entries(Rest, FoldFun, Acc, From, To)
    end.

-spec read_committed_entries() -> {ok, [journal_entry()]} | {error, term()}.
read_committed_entries() ->
    case read_journal_entries() of
        {ok, Entries} ->
            {ok, Entries};
        {error, not_found} ->
            case legacy_data_present() of
                {ok, false} ->
                    {ok, []};
                {ok, true} ->
                    {error, legacy_migration_required};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec read_journal_entries() -> {ok, [journal_entry()]} | {error, term()}.
read_journal_entries() ->
    case read_terms(journal_path()) of
        {ok, Entries} ->
            validate_journal_entries(Entries);
        {error, Reason} ->
            {error, Reason}
    end.

-spec validate_journal_entries([term()]) -> {ok, [journal_entry()]} | {error, invalid_journal}.
validate_journal_entries(Entries) ->
    case lists:all(fun is_journal_entry/1, Entries) of
        true ->
            SortedEntries = lists:keysort(1, Entries),
            case unique_positions(SortedEntries) of
                true ->
                    {ok, SortedEntries};
                false ->
                    {error, invalid_journal}
            end;
        false ->
            {error, invalid_journal}
    end.

-spec is_journal_entry(term()) -> boolean().
is_journal_entry({Position, #{stream_id := _, sequence := Sequence}}) when
    is_integer(Position), Position >= 0, is_integer(Sequence), Sequence >= 0
->
    true;
is_journal_entry(_) ->
    false.

-spec unique_positions([journal_entry()]) -> boolean().
unique_positions([]) ->
    true;
unique_positions([{Position, _} | Rest]) ->
    unique_positions(Rest, Position).

-spec unique_positions([journal_entry()], es_contract_event_store:position()) -> boolean().
unique_positions([], _PreviousPosition) ->
    true;
unique_positions([{Position, _} | _Rest], Position) ->
    false;
unique_positions([{Position, _} | Rest], _PreviousPosition) ->
    unique_positions(Rest, Position).

%% A legacy split log must be checked and committed as a canonical journal at startup.
-spec legacy_data_present() -> {ok, boolean()} | {error, atom() | {no_translation, binary()}}.
legacy_data_present() ->
    case legacy_event_files_present() of
        {ok, true} ->
            {ok, true};
        {ok, false} ->
            legacy_global_index_present();
        {error, Reason} ->
            {error, Reason}
    end.

-spec legacy_event_files_present() ->
    {ok, boolean()} | {error, atom() | {no_translation, binary()}}.
legacy_event_files_present() ->
    case file:list_dir(events_dir()) of
        {ok, Names} ->
            {ok, lists:any(fun is_legacy_event_file/1, Names)};
        {error, enoent} ->
            {ok, false};
        {error, Reason} ->
            {error, Reason}
    end.

-spec is_legacy_event_file(file:filename_all()) -> boolean().
is_legacy_event_file(Name) when is_binary(Name) ->
    filename:extension(Name) =:= list_to_binary(?EVENT_EXT);
is_legacy_event_file(Name) ->
    filename:extension(Name) =:= ?EVENT_EXT.

-spec legacy_global_index_present() -> {ok, boolean()} | {error, atom()}.
legacy_global_index_present() ->
    case file:read_file_info(legacy_global_index_path()) of
        {ok, _} ->
            {ok, true};
        {error, enoent} ->
            {ok, false};
        {error, Reason} ->
            {error, Reason}
    end.

-spec initialize_journal() ->
    ok | {error, atom() | {no_translation, binary()} | {integer(), atom(), term()}}.
initialize_journal() ->
    case read_journal_entries() of
        {ok, _} ->
            ok;
        {error, not_found} ->
            case legacy_data_present() of
                {ok, true} -> migrate_legacy_journal();
                {ok, false} -> ok;
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% Keep the old files as a backup, but only commit a migrated log when its
%% index accounts for every stored event and preserves the global positions.
-spec migrate_legacy_journal() -> ok | {error, atom() | {integer(), atom(), term()}}.
migrate_legacy_journal() ->
    case read_terms(legacy_global_index_path()) of
        {ok, Index} ->
            try
                Paths = filelib:wildcard(filename:join(events_dir(), "*" ++ ?EVENT_EXT)),
                Events = lists:flatmap(
                    fun(Path) ->
                        {ok, Terms} = read_terms(Path),
                        Terms
                    end,
                    Paths
                ),
                ByKey = maps:from_list([{es_contract_event:key(Event), Event} || Event <- Events]),
                true = map_size(ByKey) =:= length(Events),
                Entries = [{Position, maps:get(Key, ByKey)} || {Position, _Path, Key} <- Index],
                true = length(Entries) =:= length(Events),
                true = lists:sort([Key || {_, _, Key} <- Index]) =:= lists:sort(maps:keys(ByKey)),
                {ok, OrderedEntries} = validate_journal_entries(Entries),
                replace_journal(OrderedEntries)
            catch
                _:_ -> {error, legacy_migration_required}
            end;
        {error, not_found} ->
            {error, legacy_migration_required};
        {error, _} = Error ->
            Error
    end.

-spec replace_journal([journal_entry()]) -> ok | {error, term()}.
replace_journal(Entries) ->
    case ensure_dir(root_dir()) of
        ok ->
            Path = journal_path(),
            TemporaryPath = journal_temporary_path(Path),
            case write_journal(TemporaryPath, Entries) of
                ok ->
                    case file:rename(TemporaryPath, Path) of
                        ok ->
                            ok;
                        {error, Reason} ->
                            _ = file:delete(TemporaryPath),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    _ = file:delete(TemporaryPath),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% ponytail: full-log replacement is O(n); use a transactional store when log size matters.
-spec write_journal(file:filename(), [journal_entry()]) -> ok | {error, term()}.
write_journal(Path, Entries) ->
    case file:open(Path, [write, raw, binary]) of
        {ok, Device} ->
            WriteResult = file:write(Device, [serialize_to_line(Entry) || Entry <- Entries]),
            SyncResult =
                case WriteResult of
                    ok ->
                        file:sync(Device);
                    {error, _} = Error ->
                        Error
                end,
            CloseResult = file:close(Device),
            journal_write_result(SyncResult, CloseResult);
        {error, Reason} ->
            {error, Reason}
    end.

-spec journal_write_result(ok | {error, atom()}, ok | {error, atom()}) -> ok | {error, atom()}.
journal_write_result(ok, ok) ->
    ok;
journal_write_result({error, Reason}, _CloseResult) ->
    {error, Reason};
journal_write_result(ok, {error, Reason}) ->
    {error, Reason}.

-spec lock_id() -> {{?MODULE, binary() | string()}, pid()}.
%% ponytail: one shared-root append lock; use PostgreSQL/Mnesia for independent VMs.
lock_id() ->
    {{?MODULE, filename:absname(root_dir())}, self()}.

-spec journal_path() -> file:filename().
journal_path() ->
    filename:join(root_dir(), ?JOURNAL_FILE).

-spec journal_temporary_path(file:filename()) -> file:filename().
journal_temporary_path(Path) ->
    Path ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive, monotonic])).

-spec legacy_global_index_path() -> file:filename().
legacy_global_index_path() ->
    filename:join(root_dir(), ?LEGACY_GLOBAL_INDEX_FILE).
