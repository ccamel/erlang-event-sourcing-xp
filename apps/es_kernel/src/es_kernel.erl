-module(es_kernel).
-moduledoc """
Public API for the event sourcing kernel.

Provides the main interface for managing aggregate lifecycles and
dispatching commands in an event-sourced system. Abstracts the
underlying supervision and routing mechanisms behind a simple,
clean API.
""".

-export([
    dispatch/1
]).

-doc """
Dispatches a command to the appropriate aggregate instance.

The command is routed to the singleton aggregate manager, which extracts
the domain (aggregate module) and stream ID from the command, then forwards
it to the correct aggregate process.

- Command is the command to dispatch.

Function returns `ok` on success, or `{error, Reason}` if routing or execution fails.
""".
-spec dispatch(Command) -> ok | {error, Reason} when
    Command :: es_contract_command:t(),
    Reason :: term().
dispatch(Command) ->
    es_kernel_mgr_aggregate:dispatch(es_kernel_mgr_aggregate, Command).
