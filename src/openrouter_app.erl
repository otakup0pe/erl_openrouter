-module(openrouter_app).
%% @private
%% OTP infrastructure -- not part of the public API.
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    openrouter_sup:start_link().

stop(_State) ->
    ok.
