#!/usr/bin/env escript
%%! -mode(compile).

-define(OUTPUT_FILE, "bom.yml").

main([Release]) ->
    write_bom(Release);
main(_) ->
    usage(),
    halt(1).

usage() ->
    io:format("Usage: generate_release_bom.escript <release-version>~n").

write_bom(Release) ->
    Files = filelib:wildcard("apps/*/src/*.app.src"),
    Apps = lists:sort(fun sort_apps/2, [read_app(File) || File <- Files]),
    Timestamp = calendar:local_time(),
    DateString = format_date(Timestamp),
    Lines = [
        io_lib:format("release: ~s~n", [Release]),
        io_lib:format("generated_at: ~s~n", [DateString]),
        "apps:\n"
    ],
    AppLines = [io_lib:format("  ~s: \"~s\"~n", [Name, Vsn]) || {Name, Vsn} <- Apps],
    ok = file:write_file(?OUTPUT_FILE, lists:flatten(Lines ++ AppLines)).

sort_apps({NameA, _}, {NameB, _}) ->
    NameA =< NameB.

read_app(File) ->
    case file:consult(File) of
        {ok, [{application, Name, Props}]} ->
            extract_vsn(File, Name, Props);
        {ok, Terms} ->
            error({unexpected_terms, File, Terms});
        {error, Reason} ->
            error({file_error, File, Reason})
    end.

extract_vsn(File, Name, Props) ->
    case lists:keyfind(vsn, 1, Props) of
        {vsn, Vsn} ->
            {atom_to_list(Name), normalize_vsn(Vsn)};
        false ->
            error({missing_vsn, File})
    end.

normalize_vsn(Vsn) when is_list(Vsn) ->
    Vsn;
normalize_vsn(Vsn) when is_binary(Vsn) ->
    binary_to_list(Vsn);
normalize_vsn(Vsn) ->
    io_lib:format("~p", [Vsn]).

format_date({{Year, Month, Day}, _Time}) ->
    lists:flatten(
        io_lib:format("~4..0B-~2..0B-~2..0B", [Year, Month, Day])
    ).
