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
%%
%% These tests pin down the fix for the catch-all bug where any
%% {failed_connect, _} (DNS broken, TCP refused, TLS failure, ...)
%% was reclassified as a timeout, making environmental bugs
%% indistinguishable from real request timeouts in logs.

timeout_error_test() ->
    Error = openrouter_error:classify(timeout),
    ?assertEqual(timeout, Error#api_error.type),
    ?assertEqual(<<"Request timed out">>, Error#api_error.message),
    ?assertEqual(timeout, maps:get(reason, Error#api_error.metadata)).

failed_connect_nxdomain_test() ->
    Reason = {failed_connect, [{to_address, {"openrouter.ai", 443}}, {inet, [inet], nxdomain}]},
    Error = openrouter_error:classify(Reason),
    ?assertEqual(connect_failed, Error#api_error.type),
    ?assertEqual(<<"DNS lookup failed: nxdomain">>, Error#api_error.message),
    ?assertEqual(Reason, maps:get(reason, Error#api_error.metadata)).

failed_connect_ehostunreach_test() ->
    Reason = {failed_connect, [{to_address, {"openrouter.ai", 443}}, {inet, [inet], ehostunreach}]},
    Error = openrouter_error:classify(Reason),
    ?assertEqual(connect_failed, Error#api_error.type),
    ?assertEqual(<<"Host unreachable">>, Error#api_error.message),
    ?assertEqual(Reason, maps:get(reason, Error#api_error.metadata)).

failed_connect_econnrefused_test() ->
    Reason = {failed_connect, [{to_address, {"openrouter.ai", 443}}, {inet, [inet], econnrefused}]},
    Error = openrouter_error:classify(Reason),
    ?assertEqual(connect_failed, Error#api_error.type),
    ?assertEqual(<<"Connection refused">>, Error#api_error.message),
    ?assertEqual(Reason, maps:get(reason, Error#api_error.metadata)).

failed_connect_unknown_sub_error_test() ->
    Reason = {failed_connect, [weird_unknown]},
    Error = openrouter_error:classify(Reason),
    ?assertEqual(connect_failed, Error#api_error.type),
    %% The unknown sub-error falls through to the generic formatter;
    %% we don't assert the exact string, only that it preserves the term.
    Msg = Error#api_error.message,
    ?assert(is_binary(Msg)),
    ?assertNotEqual(nomatch, binary:match(Msg, <<"weird_unknown">>)),
    ?assertEqual(Reason, maps:get(reason, Error#api_error.metadata)).

unknown_error_test() ->
    Error = openrouter_error:classify(something_weird),
    ?assertEqual(server_error, Error#api_error.type),
    ?assertEqual(something_weird, maps:get(reason, Error#api_error.metadata)).

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
