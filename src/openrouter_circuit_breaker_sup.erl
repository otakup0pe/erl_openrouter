-module(openrouter_circuit_breaker_sup).
%% @private
-behaviour(supervisor).

-export([start_link/0, ensure/1, ensure/2]).
-export([init/1]).

-ifdef(TEST).
-export([breaker_opts/2]).
-endif.

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

-type breaker_ref() :: pid() | openrouter_circuit_breaker | undefined.

-spec ensure(binary() | undefined) -> breaker_ref().
ensure(Model) ->
    ensure(Model, undefined).

-spec ensure(binary() | undefined, atom() | undefined) -> breaker_ref().
ensure(Model, Op) when is_binary(Model) ->
    Key = {Model, Op},
    case lookup(Key) of
        {ok, Pid} -> Pid;
        not_found -> start_breaker(Key)
    end;
ensure(_, _) ->
    resolve_global().

lookup(Key) ->
    try ets:lookup(?TAB, Key) of
        [{Key, Pid}] when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> {ok, Pid};
                false ->
                    ets:delete(?TAB, Key),
                    not_found
            end;
        _ ->
            not_found
    catch
        error:badarg -> not_found
    end.

start_breaker({Model, Op} = Key) ->
    Opts = breaker_opts(Model, Op),
    case supervisor:start_child(?MODULE, [Opts#{model => Model, op => Op}]) of
        {ok, Pid} ->
            ets:insert(?TAB, {Key, Pid}),
            Pid;
        {error, _} ->
            case lookup(Key) of
                {ok, Pid} -> Pid;
                not_found -> resolve_global()
            end
    end.

%% @doc Compute breaker opts by layered merge.
%%
%% Precedence (later overrides earlier):
%%   1. `circuit_breaker_opts' (default)
%%   2. `per_model_circuit_breaker_opts' keyed by model
%%   3. `per_op_circuit_breaker_opts' keyed by operation
%%   4. `per_op_circuit_breaker_opts' keyed by `{Model, Operation}'
%%
breaker_opts(Model, Op) ->
    Default = application:get_env(erl_openrouter, circuit_breaker_opts,
                                  #{failure_threshold => 5,
                                    reset_timeout => 30000}),
    PerModel = application:get_env(erl_openrouter,
                                   per_model_circuit_breaker_opts, #{}),
    PerOp = application:get_env(erl_openrouter,
                                per_op_circuit_breaker_opts, #{}),
    Layers = [
        Default,
        maps:get(Model, PerModel, #{}),
        maps:get(Op, PerOp, #{}),
        maps:get({Model, Op}, PerOp, #{})
    ],
    Merge = fun(Layer, Acc) -> maps:merge(Acc, Layer) end,
    lists:foldl(Merge, #{}, Layers).

resolve_global() ->
    case whereis(openrouter_circuit_breaker) of
        undefined -> undefined;
        _Pid -> openrouter_circuit_breaker
    end.
