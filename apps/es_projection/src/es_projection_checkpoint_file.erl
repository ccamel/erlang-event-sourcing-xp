-module(es_projection_checkpoint_file).
-moduledoc """
File-backed projection checkpoint store.

Each projection checkpoint is stored as an atomically replaced binary term under
a configurable directory. It survives projection-process and VM restarts.
""".

-behaviour(es_contract_projection_checkpoint_store).

-export([
    start/0,
    stop/0,
    load_checkpoint/1,
    store_checkpoint/2
]).

-define(DEFAULT_ROOT_DIR, "./data/projection-checkpoints").
-define(CHECKPOINT_EXT, ".checkpoint").

-spec start() -> ok | {error, atom()}.
start() ->
    ensure_dir(root_dir()).

-spec stop() -> ok.
stop() ->
    ok.

-spec load_checkpoint(atom()) ->
    {ok, es_contract_event_store:position()} | {error, not_found | term()}.
load_checkpoint(ProjectionName) ->
    Path = checkpoint_path(ProjectionName),
    case file:read_file(Path) of
        {ok, Binary} ->
            decode_checkpoint(Binary);
        {error, enoent} ->
            {error, not_found};
        {error, Reason} ->
            {error, Reason}
    end.

-spec store_checkpoint(atom(), es_contract_event_store:position()) -> ok | {error, term()}.
store_checkpoint(ProjectionName, Position) when is_integer(Position), Position >= 0 ->
    case ensure_dir(root_dir()) of
        ok ->
            write_checkpoint(checkpoint_path(ProjectionName), Position);
        {error, Reason} ->
            {error, Reason}
    end;
store_checkpoint(_ProjectionName, _Position) ->
    {error, invalid_position}.

-spec write_checkpoint(file:filename(), es_contract_event_store:position()) ->
    ok | {error, atom()}.
write_checkpoint(Path, Position) ->
    TemporaryPath = Path ++ ".tmp",
    case file:write_file(TemporaryPath, term_to_binary(Position), [sync]) of
        ok ->
            case file:rename(TemporaryPath, Path) of
                ok ->
                    ok;
                {error, Reason} ->
                    _ = file:delete(TemporaryPath),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec decode_checkpoint(binary()) -> {ok, es_contract_event_store:position()} | {error, term()}.
decode_checkpoint(Binary) ->
    try binary_to_term(Binary, [safe]) of
        Position when is_integer(Position), Position >= 0 ->
            {ok, Position};
        _ ->
            {error, invalid_checkpoint}
    catch
        error:badarg ->
            {error, invalid_checkpoint}
    end.

-spec checkpoint_path(atom()) -> file:filename().
checkpoint_path(ProjectionName) ->
    Filename = binary_to_list(binary:encode_hex(atom_to_binary(ProjectionName, utf8))),
    filename:join(root_dir(), Filename ++ ?CHECKPOINT_EXT).

-spec root_dir() -> file:filename().
root_dir() ->
    to_string(application:get_env(es_projection, checkpoint_file_dir, ?DEFAULT_ROOT_DIR)).

-spec ensure_dir(file:filename()) -> ok | {error, atom()}.
ensure_dir(Dir) ->
    filelib:ensure_dir(filename:join(Dir, ".keep")).

-spec to_string(list() | binary() | atom()) -> string().
to_string(Value) when is_list(Value) ->
    Value;
to_string(Value) when is_binary(Value) ->
    binary_to_list(Value);
to_string(Value) when is_atom(Value) ->
    atom_to_list(Value).
