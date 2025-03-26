-module(event_sourcing_core_store_ets).

-behaviour(event_sourcing_core_store).

-include_lib("event_sourcing_core.hrl").

-export([start/0, stop/0, retrieve_and_fold_events/4, persist_events/2]).

-export_type([event/0, stream_id/0]).

-record(event_record,
        {key :: event_id(), stream_id :: stream_id(), sequence :: sequence(), event :: event()}).

%% @doc The name of the ETS table that will store events.
-define(EVENT_TABLE_NAME, events).

-spec start() -> ok.
start() ->
    case ets:info(?EVENT_TABLE_NAME) of
        undefined ->
            _ = ets:new(?EVENT_TABLE_NAME,
                        [ordered_set, named_table, public, {keypos, #event_record.key}]),
            ok;
        _ ->
            ok
    end.

-spec stop() -> ok.
stop() ->
    ets:delete(?EVENT_TABLE_NAME),
    ok.

-spec persist_events(StreamId, Events) -> ok
    when StreamId :: stream_id(),
         Events :: [event()].
persist_events(_, Events) ->
    Records = lists:map(fun event_to_record/1, Events),
    case ets:insert_new(?EVENT_TABLE_NAME, Records) of
        true ->
            ok;
        false ->
            erlang:error(duplicate_event)
    end.

-spec retrieve_and_fold_events(StreamId, Options, Fun, Acc0) -> Acc1
    when StreamId :: stream_id(),
         Options :: event_sourcing_core_store:fold_events_opts(),
         Fun :: fun((Event :: event(), AccIn) -> AccOut),
         Acc0 :: term(),
         Acc1 :: term(),
         AccIn :: term(),
         AccOut :: term().
retrieve_and_fold_events(StreamId, Options, FoldFun, InitialAcc)
    when is_map(Options), is_function(FoldFun, 2) ->
    From = maps:get(from, Options, 0),
    To = maps:get(to, Options, infinity),
    Limit = maps:get(limit, Options, infinity),

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
    lists:foldl(FoldFun, InitialAcc, ResultEvents).

event_to_record(Event) ->
    #event_record{key = event_sourcing_core_store:id(Event),
                  stream_id = event_sourcing_core_store:stream_id(Event),
                  sequence = event_sourcing_core_store:sequence(Event),
                  event = Event}.
