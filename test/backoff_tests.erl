-module(backoff_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tests for openrouter_backoff exponential backoff with jitter.

initial_delay_test() ->
    Delay = openrouter_backoff:delay(1, #{base => 1000, max => 60000}),
    %% First attempt: base * 2^0 = 1000ms, with jitter should be 500-1500
    ?assert(Delay >= 500),
    ?assert(Delay =< 1500).

exponential_growth_test() ->
    %% Attempt 2: base * 2^1 = 2000ms center
    D2 = openrouter_backoff:delay(2, #{base => 1000, max => 60000}),
    ?assert(D2 >= 1000),
    ?assert(D2 =< 3000),
    %% Attempt 3: base * 2^2 = 4000ms center
    D3 = openrouter_backoff:delay(3, #{base => 1000, max => 60000}),
    ?assert(D3 >= 2000),
    ?assert(D3 =< 6000).

respects_max_delay_test() ->
    %% Attempt 20 with base 1000 would be huge, but max caps it
    Delay = openrouter_backoff:delay(20, #{base => 1000, max => 5000}),
    ?assert(Delay =< 5000).

jitter_varies_test() ->
    %% Multiple calls should not all return the same value
    Opts = #{base => 1000, max => 60000},
    Delays = [openrouter_backoff:delay(3, Opts) || _ <- lists:seq(1, 20)],
    Unique = lists:usort(Delays),
    %% With 20 samples and jitter, should have at least a few unique values
    ?assert(length(Unique) > 1).

default_options_test() ->
    %% Should work with no options, using defaults
    Delay = openrouter_backoff:delay(1),
    ?assert(is_integer(Delay)),
    ?assert(Delay > 0).

zero_attempt_test() ->
    %% Attempt 0 should still produce a valid delay
    Delay = openrouter_backoff:delay(0, #{base => 1000, max => 60000}),
    ?assert(Delay >= 0),
    ?assert(Delay =< 1500).


