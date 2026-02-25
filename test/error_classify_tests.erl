-module(error_classify_tests).
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

%% Tests that openrouter_error classifies HTTP status codes and
%% error bodies into typed api_error records per OpenAPI spec.

%% classify/2 -- HTTP status code + body

auth_error_401_test() ->
    {ok, Body} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 401, <<"message">> => <<"Invalid API key">>}
    }),
    Error = openrouter_error:classify(401, Body),
    ?assertEqual(auth_error, Error#api_error.type),
    ?assertEqual(401, Error#api_error.code),
    ?assertEqual(<<"Invalid API key">>, Error#api_error.message).

insufficient_credits_402_test() ->
    {ok, Body} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 402, <<"message">> => <<"Out of credits">>}
    }),
    Error = openrouter_error:classify(402, Body),
    ?assertEqual(insufficient_credits, Error#api_error.type),
    ?assertEqual(402, Error#api_error.code).

forbidden_403_test() ->
    {ok, Body} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 403, <<"message">> => <<"Forbidden">>}
    }),
    Error = openrouter_error:classify(403, Body),
    ?assertEqual(forbidden, Error#api_error.type).

rate_limited_429_test() ->
    {ok, Body} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 429, <<"message">> => <<"Too many requests">>}
    }),
    Error = openrouter_error:classify(429, Body),
    ?assertEqual(rate_limited, Error#api_error.type),
    ?assertEqual(<<"Too many requests">>, Error#api_error.message).

server_error_500_test() ->
    {ok, Body} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 500, <<"message">> => <<"Internal error">>}
    }),
    Error = openrouter_error:classify(500, Body),
    ?assertEqual(server_error, Error#api_error.type).

server_error_502_test() ->
    {ok, Body} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 502, <<"message">> => <<"Bad gateway">>}
    }),
    Error = openrouter_error:classify(502, Body),
    ?assertEqual(server_error, Error#api_error.type).

unparseable_body_uses_status_test() ->
    Error = openrouter_error:classify(429, <<"not json">>),
    ?assertEqual(rate_limited, Error#api_error.type),
    ?assertEqual(429, Error#api_error.code).

error_with_metadata_test() ->
    {ok, Body} = openrouter_json:encode(#{
        <<"error">> => #{
            <<"code">> => 429,
            <<"message">> => <<"Rate limited">>,
            <<"metadata">> => #{<<"retry_after">> => 30}
        }
    }),
    Error = openrouter_error:classify(429, Body),
    ?assertEqual(#{<<"retry_after">> => 30}, Error#api_error.metadata).

%% classify/1 -- connection-level errors

timeout_error_test() ->
    Error = openrouter_error:classify(timeout),
    ?assertEqual(timeout, Error#api_error.type).

connection_failure_test() ->
    Error = openrouter_error:classify({failed_connect, some_reason}),
    ?assertEqual(timeout, Error#api_error.type).

unknown_error_test() ->
    Error = openrouter_error:classify(something_weird),
    ?assertEqual(server_error, Error#api_error.type).

%% from_body/1 -- parse error from response body map

from_body_with_code_test() ->
    Map = #{<<"error">> => #{<<"code">> => 401, <<"message">> => <<"Bad key">>}},
    Error = openrouter_error:from_body(Map),
    ?assertEqual(auth_error, Error#api_error.type),
    ?assertEqual(401, Error#api_error.code),
    ?assertEqual(<<"Bad key">>, Error#api_error.message).

from_body_without_code_test() ->
    Map = #{<<"error">> => #{<<"message">> => <<"Something broke">>}},
    Error = openrouter_error:from_body(Map),
    ?assertEqual(server_error, Error#api_error.type),
    ?assertEqual(<<"Something broke">>, Error#api_error.message).
