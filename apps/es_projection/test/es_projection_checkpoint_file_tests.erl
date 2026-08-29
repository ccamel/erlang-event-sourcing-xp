-module(es_projection_checkpoint_file_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STORE, {es_store_ets, es_store_ets}).
-define(STREAM, {user, <<"file-checkpoint-account">>}).

suite_test_() ->
    Tests = [
        {"stores_latest_checkpoint_across_restart", fun stores_latest_checkpoint_across_restart/0},
        {"projection_runner_uses_file_checkpoint_store",
            fun projection_runner_uses_file_checkpoint_store/0},
        {"returns_file_errors", fun returns_file_errors/0},
        {"rejects_invalid_positions", fun rejects_invalid_positions/0},
        {"returns_write_errors", fun returns_write_errors/0},
        {"cleans_up_after_rename_errors", fun cleans_up_after_rename_errors/0},
        {"rejects_malformed_checkpoints", fun rejects_malformed_checkpoints/0},
        {"accepts_binary_and_atom_checkpoint_directories",
            fun accepts_binary_and_atom_checkpoint_directories/0}
    ],
    {foreach, fun setup/0, fun teardown/1, Tests}.

setup() ->
    RootDir = filename:join([
        "_build",
        "test",
        "es_projection_checkpoint_file",
        integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = application:set_env(es_projection, checkpoint_file_dir, RootDir),
    ok = es_store_ets:start(),
    ok = es_projection_checkpoint_file:start(),
    RootDir.

teardown(RootDir) ->
    ok = es_projection_checkpoint_file:stop(),
    ok = es_store_ets:stop(),
    ok = application:unset_env(es_projection, checkpoint_file_dir),
    _ = file:del_dir_r(RootDir),
    ok.

stores_latest_checkpoint_across_restart() ->
    ?assertEqual(
        {error, not_found}, es_projection_checkpoint_file:load_checkpoint(file_projection)
    ),
    ?assertEqual(ok, es_projection_checkpoint_file:store_checkpoint(file_projection, 3)),
    ?assertEqual(ok, es_projection_checkpoint_file:store_checkpoint(file_projection, 8)),
    ?assertEqual(ok, es_projection_checkpoint_file:stop()),
    ?assertEqual(ok, es_projection_checkpoint_file:start()),
    ?assertEqual({ok, 8}, es_projection_checkpoint_file:load_checkpoint(file_projection)).

projection_runner_uses_file_checkpoint_store() ->
    Event = es_kernel_store:new_event(?STREAM, user, created, 1, erlang:system_time(), #{}),
    ?assertEqual(ok, es_kernel_store:append(?STORE, ?STREAM, [Event])),
    {ok, Pid} = es_projection:start_link(
        ?STORE,
        es_projection_collect,
        #{checkpoint_store => es_projection_checkpoint_file, poll_interval => 20}
    ),
    try
        wait_for_checkpoint(collect_projection, 0, 20)
    after
        es_projection:stop(Pid)
    end.

returns_file_errors() ->
    RootDir = checkpoint_root_dir(),
    FileRoot = filename:join(RootDir, "not_a_directory"),
    ok = file:write_file(FileRoot, <<>>),
    ok = application:set_env(es_projection, checkpoint_file_dir, FileRoot),
    ?assertMatch({error, _}, es_projection_checkpoint_file:start()),
    ?assertMatch({error, _}, es_projection_checkpoint_file:load_checkpoint(file_error_projection)),
    ?assertMatch(
        {error, _}, es_projection_checkpoint_file:store_checkpoint(file_error_projection, 0)
    ),
    ok = application:set_env(es_projection, checkpoint_file_dir, RootDir).

rejects_invalid_positions() ->
    ?assertEqual(
        {error, invalid_position},
        es_projection_checkpoint_file:store_checkpoint(invalid_position_projection, -1)
    ).

returns_write_errors() ->
    Path = checkpoint_path(write_error_projection),
    ok = file:make_dir(Path ++ ".tmp"),
    ?assertMatch(
        {error, _}, es_projection_checkpoint_file:store_checkpoint(write_error_projection, 0)
    ),
    ok = file:del_dir(Path ++ ".tmp").

cleans_up_after_rename_errors() ->
    Path = checkpoint_path(rename_error_projection),
    ok = file:make_dir(Path),
    ?assertMatch(
        {error, _}, es_projection_checkpoint_file:store_checkpoint(rename_error_projection, 0)
    ),
    ?assertNot(filelib:is_file(Path ++ ".tmp")),
    ok = file:del_dir(Path).

rejects_malformed_checkpoints() ->
    Path = checkpoint_path(malformed_checkpoint_projection),
    ok = file:write_file(Path, term_to_binary(-1)),
    ?assertEqual(
        {error, invalid_checkpoint},
        es_projection_checkpoint_file:load_checkpoint(malformed_checkpoint_projection)
    ),
    ok = file:write_file(Path, <<"not an external term">>),
    ?assertEqual(
        {error, invalid_checkpoint},
        es_projection_checkpoint_file:load_checkpoint(malformed_checkpoint_projection)
    ).

accepts_binary_and_atom_checkpoint_directories() ->
    RootDir = checkpoint_root_dir(),
    ok = application:set_env(es_projection, checkpoint_file_dir, list_to_binary(RootDir)),
    ?assertEqual(ok, es_projection_checkpoint_file:start()),
    AtomRootDir = projection_checkpoint_file_atom_root,
    ok = application:set_env(es_projection, checkpoint_file_dir, AtomRootDir),
    ?assertEqual(ok, es_projection_checkpoint_file:start()),
    ok = application:set_env(es_projection, checkpoint_file_dir, RootDir),
    _ = file:del_dir_r(atom_to_list(AtomRootDir)).

checkpoint_root_dir() ->
    {ok, RootDir} = application:get_env(es_projection, checkpoint_file_dir),
    RootDir.

checkpoint_path(ProjectionName) ->
    Filename = binary_to_list(binary:encode_hex(atom_to_binary(ProjectionName, utf8))),
    filename:join(checkpoint_root_dir(), Filename ++ ".checkpoint").

wait_for_checkpoint(_ProjectionName, _ExpectedPosition, 0) ->
    ?assert(false);
wait_for_checkpoint(ProjectionName, ExpectedPosition, AttemptsLeft) ->
    case es_projection_checkpoint_file:load_checkpoint(ProjectionName) of
        {ok, ExpectedPosition} ->
            ok;
        _ ->
            timer:sleep(20),
            wait_for_checkpoint(ProjectionName, ExpectedPosition, AttemptsLeft - 1)
    end.
