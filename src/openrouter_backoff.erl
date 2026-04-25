-module(openrouter_backoff).
%% @private
%% Internal module -- use {@link openrouter} for the public API.

%% @doc Exponential backoff with jitter for retryable errors.
%%
%% Formula: `base * 2^(attempt-1)', capped at `max', then jittered
%% to a random value in the range `[half, full]' where half is half the
%% computed delay and full is the computed delay.
%%
%% Defaults (overridable via the opts map passed to {@link delay/2}):
%% <ul>
%%   <li>`base' -- 1000 ms</li>
%%   <li>`max' -- 60000 ms</li>
%% </ul>
%%
%% Used by {@link openrouter_client} to space retries on 429 and 5xx
%% responses.

-export([delay/1, delay/2]).

-define(DEFAULT_BASE, 1000).
-define(DEFAULT_MAX, 60000).

-spec delay(Attempt :: non_neg_integer()) -> pos_integer().
delay(Attempt) ->
    delay(Attempt, #{}).

-spec delay(Attempt :: non_neg_integer(), Opts :: map()) -> pos_integer().
delay(Attempt, Opts) ->
    Base = maps:get(base, Opts, ?DEFAULT_BASE),
    Max = maps:get(max, Opts, ?DEFAULT_MAX),
    Exp = case Attempt of
        0 -> Base;
        N -> min(Base * (1 bsl (N - 1)), Max)
    end,
    Half = Exp div 2,
    Range = max(Exp, 1),
    Jittered = Half + rand:uniform(Range),
    min(Jittered, Max).


