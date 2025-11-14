-module(es_core_mgr_behaviour).
-moduledoc """
Defines the behaviour for routing commands in the event-sourcing framework.

This module specifies the callbacks used by the
`es_core_mgr_aggregate` module to determine the routing information
for commands.

Implementations of this behaviour are responsible for extracting routing information,
enabling the aggregate manager to dispatch commands to the correct aggregate instance.
""".
-include_lib("es_contract/include/es_contract.hrl").

-doc """
Extracts the routing information from the command.

The routing information is the aggregate module and the stream id.
""".
-callback extract_routing(Command :: command()) -> {ok, Route} | {error, Reason} when
    Route :: {Aggregate :: module(), Id :: stream_id()},
    Reason :: term().
