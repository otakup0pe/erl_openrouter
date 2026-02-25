-module(openrouter_backoff).

-export([delay/1, delay/2, wait/1, wait/2]).

-define(DEFAULT_BASE, 1000).
-define(DEFAULT_MAX, 60000).

-spec delay(Attempt :: non_neg_integer()) -> pos_integer().
delay(Attempt) ->
    delay(Attempt, #{}).

-spec delay(Attempt :: non_neg_integer(), Opts :: map()) -> pos_integer().
delay(Attempt, Opts) ->
    Base = maps:get(base, Opts, ?DEFAULT_BASE),
    Max = maps:get(max, Opts, ?DEFAULT_MAX),
    %% Exponential: base * 2^(attempt-1), capped at max
    Exp = case Attempt of
        0 -> Base;
        N -> min(Base * (1 bsl (N - 1)), Max)
    end,
    %% Full jitter: uniform random in [Exp/2, Exp * 1.5]
    Half = Exp div 2,
    Range = max(Exp, 1),
    Jittered = Half + rand:uniform(Range),
    min(Jittered, Max).

-spec wait(Attempt :: non_neg_integer()) -> pos_integer().
wait(Attempt) ->
    wait(Attempt, #{}).

-spec wait(Attempt :: non_neg_integer(), Opts :: map()) -> pos_integer().
wait(Attempt, Opts) ->
    Delay = delay(Attempt, Opts),
    timer:sleep(Delay),
    Delay.
