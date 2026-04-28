-module(openrouter_circuit_breaker_sup).
%% @private
-behaviour(supervisor).

-export([start_link/0, ensure/1]).
-export([init/1]).

-define(TAB, openrouter_circuit_breaker_registry).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    _ = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 60
    },
    ChildSpec = #{
        id => openrouter_circuit_breaker,
        start => {openrouter_circuit_breaker, start_link, []},
        restart => temporary,
        type => worker
    },
    {ok, {SupFlags, [ChildSpec]}}.

-spec ensure(binary() | undefined) -> pid() | atom() | undefined.
ensure(Model) when is_binary(Model) ->
    case lookup(Model) of
        {ok, Pid} -> Pid;
        not_found -> start_breaker(Model)
    end;
ensure(_) ->
    resolve_global().

lookup(Model) ->
    try ets:lookup(?TAB, Model) of
        [{Model, Pid}] when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> {ok, Pid};
                false ->
                    ets:delete(?TAB, Model),
                    not_found
            end;
        _ ->
            not_found
    catch
        error:badarg -> not_found
    end.

start_breaker(Model) ->
    Opts = breaker_opts(Model),
    case supervisor:start_child(?MODULE, [Opts#{model => Model}]) of
        {ok, Pid} ->
            ets:insert(?TAB, {Model, Pid}),
            Pid;
        {error, _} ->
            case lookup(Model) of
                {ok, Pid} -> Pid;
                not_found -> resolve_global()
            end
    end.

breaker_opts(Model) ->
    PerModel = application:get_env(erl_openrouter,
                                   per_model_circuit_breaker_opts, #{}),
    Default = application:get_env(erl_openrouter, circuit_breaker_opts,
                                  #{failure_threshold => 5,
                                    reset_timeout => 30000}),
    maps:get(Model, PerModel, Default).

resolve_global() ->
    case whereis(openrouter_circuit_breaker) of
        undefined -> undefined;
        _Pid -> openrouter_circuit_breaker
    end.
