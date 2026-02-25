-module(mock_openrouter).

%% Shared mock server for CT suites.
%% Starts a local cowboy instance that validates request structure
%% and returns canned OpenAPI-conformant responses.

-export([start/0, start/1, stop/0, port/0]).
-export([set_response/1, set_response/2, set_handler/1]).
-export([last_request/0, request_count/0, reset/0]).

%% Cowboy handler callbacks
-export([init/2]).

-define(DEFAULT_PORT, 0). %% Let OS pick a free port
-define(MOCK_TAB, mock_openrouter_state).

start() ->
    start(#{}).

start(_Opts) ->
    ets:new(?MOCK_TAB, [named_table, public, set]),
    ets:insert(?MOCK_TAB, {response, default_success_response()}),
    ets:insert(?MOCK_TAB, {handler, undefined}),
    ets:insert(?MOCK_TAB, {last_request, undefined}),
    ets:insert(?MOCK_TAB, {request_count, 0}),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/api/v1/chat/completions", ?MODULE, chat_completions},
            {"/api/v1/models", ?MODULE, models},
            {"/api/v1/auth/key", ?MODULE, auth_key},
            {"/api/v1/credits", ?MODULE, credits}
        ]}
    ]),
    {ok, _} = cowboy:start_clear(mock_openrouter_listener,
        [{port, ?DEFAULT_PORT}],
        #{env => #{dispatch => Dispatch}}
    ),
    ok.

stop() ->
    cowboy:stop_listener(mock_openrouter_listener),
    catch ets:delete(?MOCK_TAB),
    ok.

port() ->
    ranch:get_port(mock_openrouter_listener).

set_response(Response) ->
    ets:insert(?MOCK_TAB, {response, Response}).

set_response(Endpoint, Response) ->
    ets:insert(?MOCK_TAB, {{response, Endpoint}, Response}).

set_handler(Fun) ->
    ets:insert(?MOCK_TAB, {handler, Fun}).

last_request() ->
    [{_, Req}] = ets:lookup(?MOCK_TAB, last_request),
    Req.

request_count() ->
    [{_, Count}] = ets:lookup(?MOCK_TAB, request_count),
    Count.

reset() ->
    ets:insert(?MOCK_TAB, {response, default_success_response()}),
    ets:insert(?MOCK_TAB, {handler, undefined}),
    ets:insert(?MOCK_TAB, {last_request, undefined}),
    ets:insert(?MOCK_TAB, {request_count, 0}).

%% Cowboy handler

init(Req0, Endpoint) ->
    Method = cowboy_req:method(Req0),
    {ok, ReqBody, Req1} = read_body(Req0),
    Headers = cowboy_req:headers(Req1),
    store_request(#{
        method => Method,
        endpoint => Endpoint,
        body => ReqBody,
        headers => Headers
    }),
    case get_handler() of
        undefined ->
            Response = get_response(Endpoint),
            send_response(Response, Req1, Endpoint);
        Fun when is_function(Fun) ->
            Fun(Method, Endpoint, ReqBody, Headers, Req1)
    end.

%% Internal

read_body(Req) ->
    read_body(Req, <<>>).

read_body(Req0, Acc) ->
    case cowboy_req:read_body(Req0) of
        {ok, Data, Req} -> {ok, <<Acc/binary, Data/binary>>, Req};
        {more, Data, Req} -> read_body(Req, <<Acc/binary, Data/binary>>)
    end.

store_request(ReqData) ->
    ets:insert(?MOCK_TAB, {last_request, ReqData}),
    ets:update_counter(?MOCK_TAB, request_count, 1).

get_handler() ->
    [{_, Handler}] = ets:lookup(?MOCK_TAB, handler),
    Handler.

get_response(Endpoint) ->
    case ets:lookup(?MOCK_TAB, {response, Endpoint}) of
        [{_, Response}] -> Response;
        [] ->
            [{_, Response}] = ets:lookup(?MOCK_TAB, response),
            Response
    end.

send_response({StatusCode, Body}, Req, Endpoint) ->
    Req2 = cowboy_req:reply(StatusCode,
        #{<<"content-type">> => <<"application/json">>},
        Body, Req),
    {ok, Req2, Endpoint};
send_response({StatusCode, Headers, Body}, Req, Endpoint) ->
    AllHeaders = maps:merge(#{<<"content-type">> => <<"application/json">>}, Headers),
    Req2 = cowboy_req:reply(StatusCode, AllHeaders, Body, Req),
    {ok, Req2, Endpoint}.

default_success_response() ->
    {ok, Body} = openrouter_json:encode(#{
        <<"id">> => <<"gen-mock-001">>,
        <<"model">> => <<"openai/gpt-3.5-turbo">>,
        <<"choices">> => [#{
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => <<"Mock response">>
            },
            <<"finish_reason">> => <<"stop">>
        }],
        <<"usage">> => #{
            <<"prompt_tokens">> => 10,
            <<"completion_tokens">> => 5,
            <<"total_tokens">> => 15
        }
    }),
    {200, Body}.
