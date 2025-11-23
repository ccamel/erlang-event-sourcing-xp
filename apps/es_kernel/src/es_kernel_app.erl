-module(es_kernel_app).
-moduledoc """
Application callback module for the event sourcing kernel.

Defines the entry point for starting and stopping the es_kernel application
within the Erlang/OTP application framework.
""".

-behaviour(application).

-export([start/2, stop/1]).

-doc """
Starts the es_kernel application.

This function is called by the application controller when starting
the es_kernel application. It starts the top-level supervisor.

- StartType is the start type (normal, takeover, or failover).
- StartArgs are application-specific start arguments.

Function returns `{ok, Pid}` where Pid is the supervisor process,
or `{error, Reason}` if startup fails.
""".
-spec start(StartType, StartArgs) -> {ok, Pid} | {error, Reason} when
    StartType :: application:start_type(),
    StartArgs :: term(),
    Pid :: pid(),
    Reason :: term().
start(_StartType, _StartArgs) ->
    es_kernel_sup:start_link().

-doc """
Stops the es_kernel application.

This function is called by the application controller when stopping
the es_kernel application.

- State is the application state returned by start/2.

Function returns `ok`.
""".
-spec stop(State) -> ok when State :: term().
stop(_State) ->
    ok.
