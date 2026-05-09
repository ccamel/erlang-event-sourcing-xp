-module(es_projection_app).

-moduledoc """
OTP application callback for the projection runtime.
""".

-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()}.
start(_StartType, _StartArgs) ->
    es_projection_checkpoint_ets:start(),
    es_projection_root_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok = es_projection_checkpoint_ets:stop(),
    ok.
