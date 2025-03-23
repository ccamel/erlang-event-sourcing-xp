-module(event_sourcing_store_ets).

-behaviour(event_sourcing_store).

-include_lib("stdlib/include/qlc.hrl").

-export([start/0, stop/0, retrieve_and_fold_events/4, persist_events/2]).

-record(event_record,
        {key :: event_sourcing_store:id(),
         stream_id :: event_sourcing_store:stream_id(),
         sequence :: event_sourcing_store:sequence(),
         event :: event_sourcing_store:event()}).

%% @doc The name of the ETS table that will store events.
-define(EVENT_TABLE_NAME, events).

-spec start() -> {ok, initialized | already_initialized}.
start() ->
    case ets:info(?EVENT_TABLE_NAME) of
        undefined ->
            _ = ets:new(?EVENT_TABLE_NAME,
                        [ordered_set, named_table, public, {keypos, #event_record.key}]),
            {ok, initialized};
        _ ->
            {ok, already_initialized}
    end.

-spec stop() -> {ok}.
stop() ->
    ets:delete(?EVENT_TABLE_NAME),
    {ok}.

-spec persist_events(StreamId :: event_sourcing_store:stream_id(),
                     Events :: [event_sourcing_store:event()]) ->
                        ok | {error, term()}.
persist_events(StreamId, Events) ->
    case check_events(StreamId, Events, []) of
        ok ->
            InsertFun =
                fun(Event) ->
                   Id = event_sourcing_store:id(Event),
                   Record =
                       #event_record{key = Id,
                                     stream_id = event_sourcing_store:stream_id(Event),
                                     sequence = event_sourcing_store:sequence(Event),
                                     event = Event},
                   ets:insert(?EVENT_TABLE_NAME, Record)
                end,
            lists:foreach(InsertFun, Events),
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

%% Helper to check that all events belong to the provided StreamId and that none
%% have already been persisted.
check_events(_StreamId, [], _Seen) ->
    ok;
check_events(StreamId, [Event | Rest], Seen) ->
    case event_sourcing_store:stream_id(Event) of
        StreamId ->
            Id = event_sourcing_store:id(Event),
            case lists:member(Id, Seen) of
                true ->
                    {error, {duplicate_event, {event_id, Id}}};
                false ->
                    case ets:lookup(?EVENT_TABLE_NAME, Id) of
                        [] ->
                            check_events(StreamId, Rest, [Id | Seen]);
                        [_Existing] ->
                            {error, {duplicate_event, {event_id, Id}}}
                    end
            end;
        WrongStream ->
            {error, {wrong_stream_id, {expected, StreamId, got, WrongStream}}}
    end.

-spec retrieve_and_fold_events(event_sourcing_store:stream_id(),
                               event_sourcing_store:fold_events_opts(),
                               event_sourcing_store:fold_events_fun(),
                               event_sourcing_store:acc()) ->
                                  {ok, event_sourcing_store:acc()}.
retrieve_and_fold_events(StreamId, Options, FoldFun, InitialAcc)
    when is_list(Options), is_function(FoldFun, 2) ->
    From = proplists:get_value(from, Options, 0),
    To = proplists:get_value(to, Options, infinity),
    Limit = proplists:get_value(limit, Options, infinity),

    Pattern = {event_record, '_', StreamId, '$1', '$2'},
    Guard = [{'>=', '$1', From}, {'<', '$1', To}],
    MatchSpec = [{Pattern, Guard, ['$2']}],
    ResultEvents =
        case Limit of
            infinity ->
                ets:select(?EVENT_TABLE_NAME, MatchSpec);
            _ ->
                Events = ets:select(?EVENT_TABLE_NAME, MatchSpec, Limit),
                case Events of
                    {EventList, _Continuation} ->
                        EventList;
                    '$end_of_table' ->
                        []
                end
        end,
    {ok, lists:foldl(FoldFun, InitialAcc, ResultEvents)}.
