-module(http_tests).
-include_lib("eunit/include/eunit.hrl").

%% Unit tests for openrouter_http:headers/1.
%% Tests the pure header-building function without making HTTP calls.

headers_with_valid_key_test() ->
    Headers = openrouter_http:headers({ok, <<"sk-or-test-123">>}),
    ?assert(lists:member({"Authorization", "Bearer sk-or-test-123"}, Headers)),
    ?assert(lists:member({"Content-Type", "application/json"}, Headers)).

headers_with_error_auth_test() ->
    Headers = openrouter_http:headers({error, no_api_key}),
    %% Should still have content-type but no auth header
    ?assert(lists:member({"Content-Type", "application/json"}, Headers)),
    ?assertNot(lists:keymember("Authorization", 1, Headers)).

headers_with_unexpected_value_test() ->
    Headers = openrouter_http:headers(undefined),
    ?assert(lists:member({"Content-Type", "application/json"}, Headers)),
    ?assertNot(lists:keymember("Authorization", 1, Headers)).

headers_with_empty_key_test() ->
    %% Even an empty binary key gets passed through
    Headers = openrouter_http:headers({ok, <<>>}),
    ?assert(lists:member({"Authorization", "Bearer "}, Headers)).

headers_auth_format_test() ->
    %% Verify the Bearer prefix is correct
    Headers = openrouter_http:headers({ok, <<"my-key">>}),
    {"Authorization", AuthValue} = lists:keyfind("Authorization", 1, Headers),
    ?assertEqual("Bearer my-key", AuthValue).
