-module(openrouter_client).
-behaviour(gen_server).

-include("openrouter.hrl").

-export([start_link/0, start_link/1]).
-export([chat/2, models/0, key_info/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
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

handle_call({chat, Messages, Opts}, _From, State) ->
    Request = openrouter_chat:build_request(Messages, Opts),
    Url = State#state.base_url ++ "/chat/completions",
    Result = with_retry(fun() ->
        case openrouter_http:post(Url, Request, State#state.auth, State#state.timeout) of
            {ok, 200, Body} ->
                openrouter_chat:parse_response(Body);
            {ok, StatusCode, Body} when StatusCode =:= 429; StatusCode >= 500 ->
                {retry, openrouter_error:classify(StatusCode, Body)};
            {ok, StatusCode, Body} ->
                {error, openrouter_error:classify(StatusCode, Body)};
            {error, Reason} ->
                {error, openrouter_error:classify(Reason)}
        end
    end, State),
    {reply, Result, State};

handle_call(models, _From, State) ->
    Url = State#state.base_url ++ "/models",
    Result = with_retry(fun() ->
        case openrouter_http:get(Url, State#state.auth, State#state.timeout) of
            {ok, 200, Body} ->
                case openrouter_json:decode(Body) of
                    {ok, #{<<"data">> := Models}} -> {ok, Models};
                    {error, _} = Err -> Err
                end;
            {ok, StatusCode, Body} when StatusCode =:= 429; StatusCode >= 500 ->
                {retry, openrouter_error:classify(StatusCode, Body)};
            {ok, StatusCode, Body} ->
                {error, openrouter_error:classify(StatusCode, Body)};
            {error, Reason} ->
                {error, openrouter_error:classify(Reason)}
        end
    end, State),
    {reply, Result, State};

handle_call(key_info, _From, State) ->
    Url = State#state.base_url ++ "/auth/key",
    Result = with_retry(fun() ->
        case openrouter_http:get(Url, State#state.auth, State#state.timeout) of
            {ok, 200, Body} ->
                case openrouter_json:decode(Body) of
                    {ok, #{<<"data">> := KeyData}} -> {ok, KeyData};
                    {error, _} = Err -> Err
                end;
            {ok, StatusCode, Body} when StatusCode =:= 429; StatusCode >= 500 ->
                {retry, openrouter_error:classify(StatusCode, Body)};
            {ok, StatusCode, Body} ->
                {error, openrouter_error:classify(StatusCode, Body)};
            {error, Reason} ->
                {error, openrouter_error:classify(Reason)}
        end
    end, State),
    {reply, Result, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% Internal

with_retry(Fun, State) ->
    with_retry(Fun, 0, State).

with_retry(Fun, Attempt, #state{max_retries = MaxRetries} = State) ->
    case Fun() of
        {retry, _} when Attempt < MaxRetries ->
            BackoffOpts = #{
                base => State#state.backoff_base,
                max => State#state.backoff_max
            },
            openrouter_backoff:wait(Attempt + 1, BackoffOpts),
            with_retry(Fun, Attempt + 1, State);
        {retry, LastError} ->
            {error, LastError};
        Other ->
            Other
    end.
