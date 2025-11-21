-module(es_kernel_mgr_behaviour).
-moduledoc """
Defines the behaviour for routing commands in the event-sourcing framework.

This module specifies the callbacks used by the
`es_kernel_mgr_aggregate` module to determine the routing information
for commands.

Implementations of this behaviour are responsible for extracting routing information,
enabling the aggregate manager to dispatch commands to the correct aggregate instance.
""".

-doc """
Extracts the routing information from the command.

The routing information is the aggregate module and the stream id.
""".
-callback extract_routing(Command :: es_contract_command:t()) -> {ok, Route} | {error, Reason} when
    Route :: {Aggregate :: module(), Id :: es_contract_command:stream_id()},
    Reason :: term().
