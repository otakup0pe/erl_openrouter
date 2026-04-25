-module(openrouter_telemetry).
%% @private
%% Internal module -- use {@link openrouter} for the public API.

%% @doc Optional telemetry integration for the OpenRouter client.
%%
%% Wraps the `telemetry' library so it is not a hard dependency. When
%% the `telemetry' module is loaded, calls are forwarded to
%% `telemetry:span/3' and `telemetry:execute/3'. Otherwise, the
%% wrapped function is called directly and events are silently dropped.

-export([span/3, event/2, event/3]).

%% @doc Execute a function inside a telemetry span.
%%
%% When telemetry is unavailable, Fun is called directly and only its
%% first return element is used (matching `telemetry:span/3' semantics).
-spec span(EventPrefix :: [atom()], Metadata :: map(), Fun :: fun()) -> term().
span(EventPrefix, Metadata, Fun) ->
    case is_enabled() of
        true ->
            telemetry:span(EventPrefix, Metadata, Fun);
        false ->
            {Result, _} = Fun(),
            Result
    end.

%% @doc Emit a telemetry event with empty metadata.
%% @equiv event(EventName, Measurements, #{})
-spec event(EventName :: [atom()], Measurements :: map()) -> ok.
event(EventName, Measurements) ->
    event(EventName, Measurements, #{}).

%% @doc Emit a telemetry event. No-op when the telemetry library is not loaded.
-spec event(EventName :: [atom()], Measurements :: map(), Metadata :: map()) -> ok.
event(EventName, Measurements, Metadata) ->
    case is_enabled() of
        true ->
            telemetry:execute(EventName, Measurements, Metadata);
        false ->
            ok
    end.

-spec is_enabled() -> boolean().
is_enabled() ->
    case persistent_term:get({?MODULE, enabled}, not_cached) of
        not_cached ->
            Result = code:is_loaded(telemetry) =/= false,
            persistent_term:put({?MODULE, enabled}, Result),
            Result;
        Cached ->
            Cached
    end.
