-module(rate_limiter_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tests for openrouter_rate_limiter token bucket implementation.
%% The rate limiter allows N requests per window, rejecting excess.

allow_within_limit_test() ->
    {ok, Pid} = openrouter_rate_limiter:start_link(#{max_tokens => 5, refill_interval => 60000}),
    ?assertEqual(ok, openrouter_rate_limiter:acquire(Pid)),
    ?assertEqual(ok, openrouter_rate_limiter:acquire(Pid)),
    ?assertEqual(ok, openrouter_rate_limiter:acquire(Pid)),
    gen_server:stop(Pid).

reject_over_limit_test() ->
    {ok, Pid} = openrouter_rate_limiter:start_link(#{max_tokens => 2, refill_interval => 60000}),
    ?assertEqual(ok, openrouter_rate_limiter:acquire(Pid)),
    ?assertEqual(ok, openrouter_rate_limiter:acquire(Pid)),
    ?assertMatch({error, rate_limited}, openrouter_rate_limiter:acquire(Pid)),
    gen_server:stop(Pid).

tokens_available_reports_correctly_test() ->
    {ok, Pid} = openrouter_rate_limiter:start_link(#{max_tokens => 3, refill_interval => 60000}),
    ?assertEqual(3, openrouter_rate_limiter:available(Pid)),
    openrouter_rate_limiter:acquire(Pid),
    ?assertEqual(2, openrouter_rate_limiter:available(Pid)),
    gen_server:stop(Pid).

refill_restores_tokens_test() ->
    {ok, Pid} = openrouter_rate_limiter:start_link(#{max_tokens => 2, refill_interval => 50}),
    openrouter_rate_limiter:acquire(Pid),
    openrouter_rate_limiter:acquire(Pid),
    ?assertMatch({error, rate_limited}, openrouter_rate_limiter:acquire(Pid)),
    %% Wait for refill
    timer:sleep(100),
    ?assertEqual(ok, openrouter_rate_limiter:acquire(Pid)),
    gen_server:stop(Pid).

does_not_exceed_max_on_refill_test() ->
    {ok, Pid} = openrouter_rate_limiter:start_link(#{max_tokens => 3, refill_interval => 50}),
    %% Don't consume any tokens, wait for refill
    timer:sleep(100),
    ?assertEqual(3, openrouter_rate_limiter:available(Pid)),
    gen_server:stop(Pid).

acquire_multiple_tokens_test() ->
    {ok, Pid} = openrouter_rate_limiter:start_link(#{max_tokens => 5, refill_interval => 60000}),
    ?assertEqual(ok, openrouter_rate_limiter:acquire(Pid, 3)),
    ?assertEqual(2, openrouter_rate_limiter:available(Pid)),
    ?assertMatch({error, rate_limited}, openrouter_rate_limiter:acquire(Pid, 3)),
    ?assertEqual(ok, openrouter_rate_limiter:acquire(Pid, 2)),
    gen_server:stop(Pid).
