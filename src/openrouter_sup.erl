-module(openrouter_sup).
%% @private
%% OTP infrastructure -- not part of the public API.
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 60
    },
    RateLimiterOpts = application:get_env(erl_openrouter, rate_limiter_opts,
                                          #{max_tokens => 60,
                                            refill_interval => 60000}),
    CircuitBreakerOpts = application:get_env(erl_openrouter, circuit_breaker_opts,
                                             #{failure_threshold => 5,
                                               reset_timeout => 30000}),
    Children = [
        #{
            id => openrouter_rate_limiter,
            start => {openrouter_rate_limiter, start_link,
                      [openrouter_rate_limiter, RateLimiterOpts]},
            restart => permanent,
            type => worker
        },
        #{
            id => openrouter_circuit_breaker,
            start => {openrouter_circuit_breaker, start_link,
                      [openrouter_circuit_breaker, CircuitBreakerOpts]},
            restart => permanent,
            type => worker
        },
        #{
            id => openrouter_client,
            start => {openrouter_client, start_link, []},
            restart => permanent,
            type => worker
        }
    ],
    {ok, {SupFlags, Children}}.
