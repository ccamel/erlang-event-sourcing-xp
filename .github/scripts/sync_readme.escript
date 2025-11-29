#!/usr/bin/env escript
%%! -smp enable -noshell
%% sync_readme.escript
%%
%% Injects the content of scripts/demo_bank.script into README.md
%% between <!-- DEMO-START --> and <!-- DEMO-END --> markers.

main([]) ->
    main(["README.md", "apps/es_xp/examples/demo_bank.script"]);
main([ReadmePath, ScriptPath]) ->
    {ok, ReadmeBin} = file:read_file(ReadmePath),
    {ok, ScriptBin} = file:read_file(ScriptPath),

    Readme = binary_to_list(ReadmeBin),
    Script = binary_to_list(ScriptBin),

    StartMarker = "<!-- DEMO-START -->",
    EndMarker   = "<!-- DEMO-END -->",

    case split_on_markers(Readme, StartMarker, EndMarker) of
        {ok, Before, _, After} ->
            NormalizedScript =
                case lists:last(Script) of
                    $\n -> Script;
                    _   -> Script ++ "\n"
                end,
            InjectedBlock =
                "```erlang\n"
                ++ NormalizedScript
                ++ "```",

            NewReadme = Before ++ StartMarker ++ "\n\n"
                        ++ InjectedBlock ++ "\n"
                        ++ EndMarker ++ After,

            ok = file:write_file(ReadmePath, NewReadme),
            io:format("~s injected to ~s~n",
                      [ScriptPath, ReadmePath]),
            halt(0);
        error ->
            io:format(
              standard_error,
              "ERROR: markers ~s / ~s not found in ~s~n",
              [StartMarker, EndMarker, ReadmePath]
            ),
            halt(1)
    end.

split_on_markers(Readme, StartMarker, EndMarker) ->
    case split_once(Readme, StartMarker) of
        nomatch ->
            error;
        {Before, AfterStart} ->
            case split_once(AfterStart, EndMarker) of
                nomatch ->
                    error;
                {Between, AfterEnd} ->
                    {ok, Before, Between, AfterEnd}
            end
    end.

split_once(Haystack, Needle) when is_list(Haystack), is_list(Needle) ->
    case Needle of
        [] -> {[], Haystack};
        _  -> find_index(Haystack, Needle, [])
    end.

find_index(Haystack, Needle, AccRev) ->
    case starts_with(Haystack, Needle) of
        true ->
            Before = lists:reverse(AccRev),
            After = drop(Haystack, length(Needle)),
            {Before, After};
        false ->
            case Haystack of
                [] -> nomatch;
                [Hh|Ht] -> find_index(Ht, Needle, [Hh|AccRev])
            end
    end.

starts_with(_, []) -> true;
starts_with([], [_|_]) -> false;
starts_with([Hh|Ht], [Nh|Nt]) when Hh =:= Nh -> starts_with(Ht, Nt);
starts_with(_, _) -> false.

%% Simple drop/2 for compatibility with older OTPs where lists:drop/2
%% may not be available.
drop(List, N) when N =< 0 -> List;
drop([], _N) -> [];
drop([_H|T], N) -> drop(T, N - 1).
