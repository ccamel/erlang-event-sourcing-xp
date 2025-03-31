-module(event_sourcing_core_mgr_behaviour).

-include_lib("event_sourcing_core.hrl").

-doc """
Extracts the routing information from the command.

The routing information is the aggregate module and the stream id.
""".
-callback extract_routing(Command :: command()) -> {ok, Route} | {error, Reason}
    when Route :: {Aggregate :: module(), Id :: stream_id()},
         Reason :: term().
