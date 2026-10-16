-module(openrouter_sup).
%% @private
%% OTP infrastructure -- not part of the public API.
%%
%% All child opts read from application env with sensible defaults.
%% Keys: client_opts, rate_limiter_opts, circuit_breaker_opts.
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
    Children = [
        #{
            id => openrouter_rate_limiter,
            start => {openrouter_rate_limiter, start_link,
                      [openrouter_rate_limiter, rl_opts()]},
            restart => permanent,
            type => worker
        },
        #{
            id => openrouter_circuit_breaker,
            %% This named worker IS the aggregate breaker --
            %% openrouter_circuit_breaker_sup:resolve_global/0 returns this
            %% registered name. It must be ratio-over-window, not
            %% consecutive: see global_opts/0 for why.
            start => {openrouter_circuit_breaker, start_link,
                      [openrouter_circuit_breaker,
                       openrouter_circuit_breaker_sup:global_opts()]},
            restart => permanent,
            type => worker
        },
        #{
            id => openrouter_circuit_breaker_sup,
            start => {openrouter_circuit_breaker_sup, start_link, []},
            restart => permanent,
            type => supervisor
        },
        #{
            id => openrouter_usage,
            start => {openrouter_usage, start_link, []},
            restart => permanent,
            type => worker
        },
        #{
            id => openrouter_client,
            start => {openrouter_client, start_link, [client_opts()]},
            restart => permanent,
            type => worker
        }
    ],
    {ok, {SupFlags, Children}}.

client_opts() ->
    application:get_env(erl_openrouter, client_opts, #{}).

rl_opts() ->
    application:get_env(erl_openrouter, rate_limiter_opts,
                        #{max_tokens => 60, refill_interval => 60000}).


