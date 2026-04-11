-module(openrouter_client).
-behaviour(gen_server).

-include("openrouter.hrl").

-export([start_link/0, start_link/1]).
-export([chat/2, embeddings/2, models/0, key_info/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    auth :: term(),
    base_url :: string(),
    timeout :: pos_integer(),
    max_retries :: non_neg_integer(),
    backoff_base :: pos_integer(),
    backoff_max :: pos_integer(),
    in_flight = #{} :: #{reference() => {term(), atom()}}
}).

-record(call_config, {
    auth :: term(),
    base_url :: string(),
    timeout :: pos_integer(),
    max_retries :: non_neg_integer(),
    backoff_base :: pos_integer(),
    backoff_max :: pos_integer()
}).

start_link() ->
    start_link(#{}).

start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

chat(Messages, Opts) ->
    gen_server:call(?MODULE, {chat, Messages, Opts}, infinity).

embeddings(Input, Opts) ->
    gen_server:call(?MODULE, {embeddings, Input, Opts}, infinity).

models() ->
    gen_server:call(?MODULE, models, infinity).

key_info() ->
    gen_server:call(?MODULE, key_info, infinity).

init(Opts) ->
    BaseUrl = maps:get(base_url, Opts,
        application:get_env(erl_openrouter, base_url, "https://openrouter.ai/api/v1")),
    Timeout = maps:get(timeout, Opts,
        application:get_env(erl_openrouter, timeout, 30000)),
    Auth = openrouter_auth:resolve(Opts),
    MaxRetries = maps:get(max_retries, Opts, 3),
    BackoffBase = maps:get(backoff_base, Opts, 1000),
    BackoffMax = maps:get(backoff_max, Opts, 30000),
    {ok, #state{
        auth = Auth,
        base_url = BaseUrl,
        timeout = Timeout,
        max_retries = MaxRetries,
        backoff_base = BackoffBase,
        backoff_max = BackoffMax
    }}.

handle_call({chat, Messages, Opts}, From, State) ->
    Config = build_call_config(Opts, State),
    Url = Config#call_config.base_url ++ "/chat/completions",
    Request = openrouter_chat:build_request(Messages, Opts),
    NewState = spawn_post(From, chat, Url, Request, Config,
                          fun openrouter_chat:parse_response/1, State),
    {noreply, NewState};

handle_call({embeddings, Input, Opts}, From, State) ->
    Config = build_call_config(Opts, State),
    Url = Config#call_config.base_url ++ "/embeddings",
    Request = openrouter_embeddings:build_request(Input, Opts),
    NewState = spawn_post(From, embeddings, Url, Request, Config,
                          fun openrouter_embeddings:parse_response/1, State),
    {noreply, NewState};

handle_call(models, From, State) ->
    Config = build_call_config(#{}, State),
    Url = Config#call_config.base_url ++ "/models",
    NewState = spawn_get(From, models, Url, Config,
                         fun openrouter_models:parse_response/1, State),
    {noreply, NewState};

handle_call(key_info, From, State) ->
    Config = build_call_config(#{}, State),
    Url = Config#call_config.base_url ++ "/auth/key",
    NewState = spawn_get(From, key_info, Url, Config,
                         fun openrouter_key:parse_response/1, State),
    {noreply, NewState};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MonRef, process, _Pid, Reason}, State) ->
    case maps:take(MonRef, State#state.in_flight) of
        {{From, Op}, NewInFlight} ->
            case Reason of
                normal ->
                    %% Worker completed successfully; reply already
                    %% delivered via gen_server:reply.
                    {noreply, State#state{in_flight = NewInFlight}};
                _ ->
                    %% Worker crashed before replying.
                    Error = {error, {worker_crashed, Op, Reason}},
                    gen_server:reply(From, Error),
                    logger:warning(
                      "openrouter_client worker for ~p crashed: ~p",
                      [Op, Reason]),
                    {noreply, State#state{in_flight = NewInFlight}}
            end;
        error ->
            %% DOWN for an unknown monitor ref; ignore
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% Internal

%% Build a snapshot of call config from gen_server state plus per-call
%% overrides. The snapshot is immutable and passed by value to worker
%% processes, which execute the HTTP call without touching shared state.
build_call_config(Opts, #state{} = State) ->
    #call_config{
        auth = resolve_request_auth(Opts, State#state.auth),
        base_url = resolve_request_url(Opts, State#state.base_url),
        timeout = resolve_request_timeout(Opts, State#state.timeout),
        max_retries = State#state.max_retries,
        backoff_base = State#state.backoff_base,
        backoff_max = State#state.backoff_max
    }.

resolve_request_auth(Opts, DefaultAuth) when is_map(Opts) ->
    case openrouter_auth:resolve(Opts) of
        {error, no_api_key} -> DefaultAuth;
        Resolved -> Resolved
    end;
resolve_request_auth(_, DefaultAuth) ->
    DefaultAuth.

resolve_request_url(Opts, DefaultUrl) when is_map(Opts) ->
    maps:get(base_url, Opts, DefaultUrl);
resolve_request_url(_, DefaultUrl) ->
    DefaultUrl.

resolve_request_timeout(Opts, DefaultTimeout) when is_map(Opts) ->
    maps:get(timeout, Opts, DefaultTimeout);
resolve_request_timeout(_, DefaultTimeout) ->
    DefaultTimeout.

spawn_post(From, Op, Url, Request, Config, ParseFun, State) ->
    {_Pid, MonRef} = spawn_monitor(fun() ->
        Result = do_post_with_retry(Url, Request, Config, ParseFun),
        gen_server:reply(From, Result)
    end),
    track_worker(From, Op, MonRef, State).

spawn_get(From, Op, Url, Config, ParseFun, State) ->
    {_Pid, MonRef} = spawn_monitor(fun() ->
        Result = do_get_with_retry(Url, Config, ParseFun),
        gen_server:reply(From, Result)
    end),
    track_worker(From, Op, MonRef, State).

track_worker(From, Op, MonRef, State) ->
    NewInFlight = maps:put(MonRef, {From, Op}, State#state.in_flight),
    State#state{in_flight = NewInFlight}.

do_post_with_retry(Url, Request, Config, ParseFun) ->
    with_retry(fun() ->
        case openrouter_http:post(Url, Request,
                                  Config#call_config.auth,
                                  Config#call_config.timeout) of
            {ok, 200, Body} ->
                ParseFun(Body);
            {ok, StatusCode, Body} when StatusCode =:= 429; StatusCode >= 500 ->
                {retry, openrouter_error:classify(StatusCode, Body)};
            {ok, StatusCode, Body} ->
                {error, openrouter_error:classify(StatusCode, Body)};
            {error, Reason} ->
                {error, openrouter_error:classify(Reason)}
        end
    end, Config).

do_get_with_retry(Url, Config, ParseFun) ->
    with_retry(fun() ->
        case openrouter_http:get(Url,
                                 Config#call_config.auth,
                                 Config#call_config.timeout) of
            {ok, 200, Body} ->
                ParseFun(Body);
            {ok, StatusCode, Body} when StatusCode =:= 429; StatusCode >= 500 ->
                {retry, openrouter_error:classify(StatusCode, Body)};
            {ok, StatusCode, Body} ->
                {error, openrouter_error:classify(StatusCode, Body)};
            {error, Reason} ->
                {error, openrouter_error:classify(Reason)}
        end
    end, Config).

with_retry(Fun, Config) ->
    with_retry(Fun, 0, Config).

with_retry(Fun, Attempt, #call_config{max_retries = MaxRetries} = Config) ->
    case Fun() of
        {retry, _} when Attempt < MaxRetries ->
            BackoffOpts = #{
                base => Config#call_config.backoff_base,
                max => Config#call_config.backoff_max
            },
            openrouter_backoff:wait(Attempt + 1, BackoffOpts),
            with_retry(Fun, Attempt + 1, Config);
        {retry, LastError} ->
            {error, LastError};
        Other ->
            Other
    end.
