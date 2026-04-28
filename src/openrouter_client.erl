-module(openrouter_client).
%% @private
%% Internal module -- use {@link openrouter} for the public API.
-behaviour(gen_server).

-include("openrouter.hrl").

-export([start_link/0, start_link/1]).
-export([chat/2, chat_stream/2, embeddings/2, models/0, key_info/0, generation/1, credits/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    auth :: term(),
    base_url :: string(),
    timeout :: pos_integer(),
    max_retries :: non_neg_integer(),
    backoff_base :: pos_integer(),
    backoff_max :: pos_integer(),
    extra_headers = [] :: [{string(), string()}],
    max_in_flight :: pos_integer(),
    call_timeout :: pos_integer(),
    in_flight = #{} :: #{reference() => {term(), atom()}}
}).

-record(call_config, {
    auth :: term(),
    base_url :: string(),
    timeout :: pos_integer(),
    max_retries :: non_neg_integer(),
    backoff_base :: pos_integer(),
    backoff_max :: pos_integer(),
    extra_headers = [] :: [{string(), string()}],
    rate_limiter :: atom() | pid() | undefined,
    circuit_breaker :: atom() | pid() | undefined
}).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(#{}).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

-spec chat([map()], map()) -> {ok, #chat_response{}} | {error, term()}.
chat(Messages, Opts) ->
    gen_server:call(?MODULE, {chat, Messages, Opts}, call_timeout()).

-spec chat_stream([map()], map()) -> {ok, reference(), pid()} | {error, term()}.
chat_stream(Messages, Opts) ->
    gen_server:call(?MODULE, {chat_stream, Messages, Opts}, call_timeout()).

-spec embeddings(binary() | [binary()], map()) -> {ok, #embedding_response{}} | {error, term()}.
embeddings(Input, Opts) ->
    gen_server:call(?MODULE, {embeddings, Input, Opts}, call_timeout()).

-spec models() -> {ok, [map()]} | {error, term()}.
models() ->
    gen_server:call(?MODULE, models, call_timeout()).

-spec key_info() -> {ok, map()} | {error, term()}.
key_info() ->
    gen_server:call(?MODULE, key_info, call_timeout()).

-spec generation(binary()) -> {ok, map()} | {error, term()}.
generation(GenId) ->
    gen_server:call(?MODULE, {generation, GenId}, call_timeout()).

-spec credits() -> {ok, map()} | {error, term()}.
credits() ->
    gen_server:call(?MODULE, credits, call_timeout()).

-spec call_timeout() -> pos_integer().
call_timeout() ->
    application:get_env(erl_openrouter, call_timeout, 90000).

init(Opts) ->
    BaseUrl = maps:get(base_url, Opts,
        application:get_env(erl_openrouter, base_url, "https://openrouter.ai/api/v1")),
    Timeout = maps:get(timeout, Opts,
        application:get_env(erl_openrouter, timeout, 30000)),
    Auth = openrouter_auth:resolve(Opts),
    MaxRetries = maps:get(max_retries, Opts, 3),
    BackoffBase = maps:get(backoff_base, Opts, 1000),
    BackoffMax = maps:get(backoff_max, Opts, 30000),
    MaxInFlight = maps:get(max_in_flight, Opts,
        application:get_env(erl_openrouter, max_in_flight, 50)),
    CallTimeout = maps:get(call_timeout, Opts,
        application:get_env(erl_openrouter, call_timeout, 90000)),
    ExtraHeaders = case maps:get(extra_headers, Opts, []) of
                       L when is_list(L) -> L;
                       _ -> []
                   end,
    {ok, #state{
        auth = Auth,
        base_url = BaseUrl,
        timeout = Timeout,
        max_retries = MaxRetries,
        backoff_base = BackoffBase,
        backoff_max = BackoffMax,
        extra_headers = ExtraHeaders,
        max_in_flight = MaxInFlight,
        call_timeout = CallTimeout
    }}.

handle_call({chat, Messages, Opts}, From, State) ->
    case check_capacity(State) of
        {error, _} = Err ->
            {reply, Err, State};
        ok ->
            Config = build_call_config(Opts, State),
            case check_auth(Config) of
                {error, _} = Err ->
                    {reply, Err, State};
                ok ->
                    Url = Config#call_config.base_url ++ "/chat/completions",
                    try openrouter_chat:build_request(Messages, Opts) of
                        Request ->
                            NewState = spawn_post(From, chat, Url, Request, Config,
                                                  fun openrouter_chat:parse_response/1, State),
                            {noreply, NewState}
                    catch
                        error:{duplicate_tool_name, _} = Reason ->
                            {reply, {error, Reason}, State};
                        error:{invalid_tool, _} = Reason ->
                            {reply, {error, Reason}, State};
                        error:{stream_not_supported, _} = Reason ->
                            {reply, {error, Reason}, State}
                    end
            end
    end;

handle_call({chat_stream, Messages, Opts}, {CallerPid, _Tag}, State) ->
    case check_capacity(State) of
        {error, _} = Err ->
            {reply, Err, State};
        ok ->
            Config = build_call_config(Opts, State),
            case check_auth(Config) of
                {error, _} = Err ->
                    {reply, Err, State};
                ok ->
                    Url = Config#call_config.base_url ++ "/chat/completions",
                    Request = openrouter_chat:build_request(Messages, Opts),
                    StreamRef = make_ref(),
                    StreamOpts = #{
                        auth => Config#call_config.auth,
                        timeout => Config#call_config.timeout,
                        extra_headers => Config#call_config.extra_headers,
                        circuit_breaker => Config#call_config.circuit_breaker
                    },
                    {WorkerPid, MonRef} = spawn_monitor(fun() ->
                        openrouter_stream_worker:start(
                            CallerPid, StreamRef, Url, Request, StreamOpts)
                    end),
                    NewInFlight = maps:put(MonRef, {{CallerPid, StreamRef}, chat_stream},
                                           State#state.in_flight),
                    {reply, {ok, StreamRef, WorkerPid}, State#state{in_flight = NewInFlight}}
            end
    end;

handle_call({embeddings, Input, Opts}, From, State) ->
    case check_capacity(State) of
        {error, _} = Err ->
            {reply, Err, State};
        ok ->
            Config = build_call_config(Opts, State),
            case check_auth(Config) of
                {error, _} = Err ->
                    {reply, Err, State};
                ok ->
                    Url = Config#call_config.base_url ++ "/embeddings",
                    Request = openrouter_embeddings:build_request(Input, Opts),
                    NewState = spawn_post(From, embeddings, Url, Request, Config,
                                          fun openrouter_embeddings:parse_response/1, State),
                    {noreply, NewState}
            end
    end;

handle_call(models, From, State) ->
    case check_capacity(State) of
        {error, _} = Err ->
            {reply, Err, State};
        ok ->
            Config = build_call_config(#{}, State),
            case check_auth(Config) of
                {error, _} = Err ->
                    {reply, Err, State};
                ok ->
                    Url = Config#call_config.base_url ++ "/models",
                    NewState = spawn_get(From, models, Url, Config,
                                         fun openrouter_models:parse_response/1, State),
                    {noreply, NewState}
            end
    end;

handle_call(key_info, From, State) ->
    case check_capacity(State) of
        {error, _} = Err ->
            {reply, Err, State};
        ok ->
            Config = build_call_config(#{}, State),
            case check_auth(Config) of
                {error, _} = Err ->
                    {reply, Err, State};
                ok ->
                    Url = Config#call_config.base_url ++ "/auth/key",
                    NewState = spawn_get(From, key_info, Url, Config,
                                         fun openrouter_key:parse_response/1, State),
                    {noreply, NewState}
            end
    end;

handle_call({generation, GenId}, From, State) ->
    case check_capacity(State) of
        {error, _} = Err ->
            {reply, Err, State};
        ok ->
            Config = build_call_config(#{}, State),
            case check_auth(Config) of
                {error, _} = Err ->
                    {reply, Err, State};
                ok ->
                    Url = Config#call_config.base_url ++ "/generation?id="
                          ++ binary_to_list(GenId),
                    NewState = spawn_get(From, generation, Url, Config,
                                         fun openrouter_generation:parse_response/1, State),
                    {noreply, NewState}
            end
    end;

handle_call(credits, From, State) ->
    case check_capacity(State) of
        {error, _} = Err ->
            {reply, Err, State};
        ok ->
            Config = build_call_config(#{}, State),
            case check_auth(Config) of
                {error, _} = Err ->
                    {reply, Err, State};
                ok ->
                    Url = Config#call_config.base_url ++ "/credits",
                    NewState = spawn_get(From, credits, Url, Config,
                                         fun openrouter_credits:parse_response/1, State),
                    {noreply, NewState}
            end
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MonRef, process, _Pid, Reason}, State) ->
    case maps:take(MonRef, State#state.in_flight) of
        {{From, Op}, NewInFlight} ->
            case Reason of
                normal ->
                    {noreply, State#state{in_flight = NewInFlight}};
                _ when Op =:= chat_stream ->
                    %% Stream reply (ok, StreamRef, WorkerPid) was already
                    %% sent. The caller is waiting for stream_event messages.
                    %% Deliver a terminal error so the caller doesn't hang.
                    {CallerPid, StreamRef} = From,
                    CallerPid ! {stream_event, StreamRef, {error, {worker_crashed, Reason}}},
                    logger:warning(
                      "openrouter_client stream worker crashed: ~p",
                      [Reason]),
                    {noreply, State#state{in_flight = NewInFlight}};
                _ ->
                    Error = {error, openrouter_error:local_error(
                        worker_crashed,
                        iolist_to_binary(io_lib:format("Worker for ~p crashed: ~p", [Op, Reason])))},
                    gen_server:reply(From, Error),
                    logger:warning(
                      "openrouter_client worker for ~p crashed: ~p",
                      [Op, Reason]),
                    {noreply, State#state{in_flight = NewInFlight}}
            end;
        error ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% Internal

check_capacity(#state{in_flight = InFlight, max_in_flight = Max}) ->
    case maps:size(InFlight) >= Max of
        true ->
            {error, openrouter_error:local_error(
                overloaded,
                <<"Too many in-flight requests">>)};
        false ->
            ok
    end.

check_auth(#call_config{auth = {error, no_api_key}}) ->
    {error, openrouter_error:local_error(
        auth_error,
        <<"No API key configured. Set OPENROUTER_API_KEY env var, "
          "erl_openrouter app env api_key, or pass auth_callback in opts.">>)};
check_auth(_) ->
    ok.

build_call_config(Opts, #state{} = State) ->
    #call_config{
        auth = resolve_request_auth(Opts, State#state.auth),
        base_url = resolve_request_url(Opts, State#state.base_url),
        timeout = resolve_request_timeout(Opts, State#state.timeout),
        max_retries = State#state.max_retries,
        backoff_base = State#state.backoff_base,
        backoff_max = State#state.backoff_max,
        extra_headers = resolve_extra_headers(Opts, State#state.extra_headers),
        rate_limiter = resolve_named_process(openrouter_rate_limiter),
        circuit_breaker = resolve_named_process(openrouter_circuit_breaker)
    }.

resolve_named_process(Name) ->
    case whereis(Name) of
        undefined -> undefined;
        _Pid -> Name
    end.

resolve_extra_headers(Opts, Default) when is_map(Opts) ->
    case maps:get(extra_headers, Opts, undefined) of
        undefined -> Default;
        L when is_list(L) -> L;
        Bad ->
            logger:warning("extra_headers must be a list, got: ~p", [Bad]),
            Default
    end;
resolve_extra_headers(_, Default) -> Default.

resolve_request_auth(Opts, DefaultAuth) when is_map(Opts) ->
    %% Support overriding of auth on a per-request basis.
    case maps:is_key(auth_callback, Opts) of
        true ->
            case openrouter_auth:resolve(Opts) of
                {error, no_api_key} -> DefaultAuth;
                Resolved -> Resolved
            end;
        false ->
            DefaultAuth
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
        Model = extract_model(Request),
        Meta = #{operation => Op, model => Model},
        Result = openrouter_telemetry:span(
            [erl_openrouter, request],
            Meta,
            fun() ->
                {Res, Attempts} = do_post_with_retry(Url, Request, Config, ParseFun),
                StopMeta = maps:merge(Meta, result_measurements(Res)),
                {Res, StopMeta#{attempts => Attempts}}
            end),
        record_usage(Model, Result),
        gen_server:reply(From, Result)
    end),
    track_worker(From, Op, MonRef, State).

spawn_get(From, Op, Url, Config, ParseFun, State) ->
    {_Pid, MonRef} = spawn_monitor(fun() ->
        Meta = #{operation => Op, model => undefined},
        Result = openrouter_telemetry:span(
            [erl_openrouter, request],
            Meta,
            fun() ->
                {Res, Attempts} = do_get_with_retry(Url, Config, ParseFun),
                StopMeta = maps:merge(Meta, result_measurements(Res)),
                {Res, StopMeta#{attempts => Attempts}}
            end),
        gen_server:reply(From, Result)
    end),
    track_worker(From, Op, MonRef, State).

track_worker(From, Op, MonRef, State) ->
    NewInFlight = maps:put(MonRef, {From, Op}, State#state.in_flight),
    State#state{in_flight = NewInFlight}.

do_post_with_retry(Url, Request, Config, ParseFun) ->
    case pre_flight_checks(Config) of
        ok ->
            {Res, Attempts} = with_retry(fun() ->
                Result = openrouter_http:post(Url, Request,
                                              Config#call_config.auth,
                                              Config#call_config.timeout,
                                              Config#call_config.extra_headers),
                classify_http_result(Result, ParseFun, Config)
            end, Config),
            {Res, Attempts};
        {error, _} = Err ->
            {Err, 0}
    end.

do_get_with_retry(Url, Config, ParseFun) ->
    case pre_flight_checks(Config) of
        ok ->
            {Res, Attempts} = with_retry(fun() ->
                Result = openrouter_http:get(Url,
                                             Config#call_config.auth,
                                             Config#call_config.timeout,
                                             Config#call_config.extra_headers),
                classify_http_result(Result, ParseFun, Config)
            end, Config),
            {Res, Attempts};
        {error, _} = Err ->
            {Err, 0}
    end.

pre_flight_checks(#call_config{circuit_breaker = CB, rate_limiter = RL}) ->
    case check_circuit_breaker(CB) of
        ok -> check_rate_limiter(RL);
        {error, _} = Err -> Err
    end.

check_circuit_breaker(undefined) -> ok;
check_circuit_breaker(CB) ->
    case openrouter_circuit_breaker:allow(CB) of
        ok -> ok;
        {error, circuit_open} ->
            {error, openrouter_error:local_error(
                circuit_open,
                <<"Circuit breaker open -- upstream appears unhealthy">>)}
    end.

check_rate_limiter(undefined) -> ok;
check_rate_limiter(RL) ->
    case openrouter_rate_limiter:acquire(RL) of
        ok -> ok;
        {error, rate_limited} ->
            openrouter_telemetry:event(
                [erl_openrouter, rate_limiter, rejected], #{}, #{}),
            {error, openrouter_error:local_error(
                rate_limited,
                <<"Local rate limiter exhausted">>)}
    end.

classify_http_result({ok, 200, Headers, Body}, ParseFun, Config) ->
    record_cb_success(Config#call_config.circuit_breaker),
    RequestId = openrouter_http:find_request_id(Headers),
    inject_request_id(ParseFun(Body), RequestId);
classify_http_result({ok, StatusCode, Headers, Body}, _ParseFun, Config)
  when StatusCode =:= 429; StatusCode >= 500 ->
    record_cb_failure(Config#call_config.circuit_breaker),
    RetryAfter = openrouter_http:parse_retry_after(Headers),
    RequestId = openrouter_http:find_request_id(Headers),
    Error = inject_request_id_into_error(
                openrouter_error:classify(StatusCode, Body), RequestId),
    {retry, Error, RetryAfter};
classify_http_result({ok, StatusCode, Headers, Body}, _ParseFun, _Config) ->
    RequestId = openrouter_http:find_request_id(Headers),
    Error = inject_request_id_into_error(
                openrouter_error:classify(StatusCode, Body), RequestId),
    {error, Error};
classify_http_result({error, Reason}, _ParseFun, Config) ->
    record_cb_failure(Config#call_config.circuit_breaker),
    {error, openrouter_error:classify(Reason)}.

record_cb_success(undefined) -> ok;
record_cb_success(CB) -> openrouter_circuit_breaker:record_success(CB).

record_cb_failure(undefined) -> ok;
record_cb_failure(CB) -> openrouter_circuit_breaker:record_failure(CB).

with_retry(Fun, Config) ->
    with_retry(Fun, 0, Config).

with_retry(Fun, Attempt, #call_config{max_retries = MaxRetries} = Config) ->
    case Fun() of
        {retry, _, RetryAfter} when Attempt < MaxRetries ->
            BackoffOpts = #{
                base => Config#call_config.backoff_base,
                max => Config#call_config.backoff_max
            },
            ComputedMs = openrouter_backoff:delay(Attempt + 1, BackoffOpts),
            RetryAfterMs = case RetryAfter of
                               N when is_integer(N), N > 0 -> N * 1000;
                               N when is_integer(N) -> 0;
                               undefined -> 0
                           end,
            DelayMs = max(ComputedMs, RetryAfterMs),
            openrouter_telemetry:event(
                [erl_openrouter, request, retry],
                #{delay_ms => DelayMs},
                #{attempt => Attempt + 1, max_retries => MaxRetries}),
            timer:sleep(DelayMs),
            case check_circuit_breaker(Config#call_config.circuit_breaker) of
                ok ->
                    with_retry(Fun, Attempt + 1, Config);
                {error, _} = Err ->
                    {Err, Attempt + 1}
            end;
        {retry, LastError, _} ->
            {{error, LastError}, Attempt + 1};
        Other ->
            {Other, Attempt + 1}
    end.

extract_model(RequestBinary) when is_binary(RequestBinary) ->
    try
        case openrouter_json:decode(RequestBinary) of
            {ok, #{<<"model">> := Model}} when is_binary(Model) -> Model;
            {ok, _} -> undefined;
            {error, _} -> undefined
        end
    catch
        error:badarg -> undefined
    end.

result_measurements({ok, #chat_response{usage = Usage}}) when is_map(Usage) ->
    #{status => ok,
      tokens_prompt => maps:get(<<"prompt_tokens">>, Usage, 0),
      tokens_completion => maps:get(<<"completion_tokens">>, Usage, 0)};
result_measurements({ok, _}) ->
    #{status => ok};
result_measurements({error, #api_error{type = Type, code = Code}}) ->
    #{status => error, error_type => Type, status_code => Code};
result_measurements({error, _}) ->
    #{status => error}.

record_usage(Model, {ok, #chat_response{usage = Usage}}) ->
    openrouter_usage:record(Model, Usage);
record_usage(Model, {ok, #embedding_response{usage = Usage}}) ->
    openrouter_usage:record(Model, Usage);
record_usage(_, _) ->
    ok.

inject_request_id({ok, #chat_response{id = BodyId} = R}, RequestId) ->
    Id = coalesce_request_id(RequestId, BodyId),
    {ok, R#chat_response{request_id = Id}};
inject_request_id({ok, #embedding_response{} = R}, RequestId) ->
    {ok, R#embedding_response{request_id = RequestId}};
inject_request_id({error, #api_error{} = E}, RequestId) ->
    {error, inject_request_id_into_error(E, RequestId)};
inject_request_id(Other, _RequestId) ->
    Other.

inject_request_id_into_error(#api_error{metadata = Meta} = E, undefined) when is_map(Meta) ->
    E;
inject_request_id_into_error(#api_error{metadata = Meta} = E, RequestId) when is_map(Meta) ->
    E#api_error{metadata = Meta#{request_id => RequestId}}.

coalesce_request_id(undefined, BodyId) when is_binary(BodyId) -> BodyId;
coalesce_request_id(HeaderId, _) when is_binary(HeaderId) -> HeaderId.
