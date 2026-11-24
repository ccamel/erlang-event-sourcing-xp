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

The singleton aggregate manager routes the command by aggregate type and ID,
then relays the result. The caller waits for that result; the manager can route
other commands while an aggregate executes. Each aggregate processes its own
commands serially. Starting an aggregate and replaying its stream still happen
in the routing path.

- Command is the command to dispatch.

Function returns `ok` on success, or `{error, Reason}` if routing or execution fails.
Version conflicts return `{error, {wrong_expected_sequence, Expected, Actual}}`.
The aggregate refreshes its state but does not retry the rejected command.
""".
-spec dispatch(Command) -> ok | {error, Reason} when
    Command :: es_contract_command:t(),
    Reason :: term().
dispatch(Command) ->
    es_kernel_mgr_aggregate:dispatch(es_kernel_mgr_aggregate, Command).
