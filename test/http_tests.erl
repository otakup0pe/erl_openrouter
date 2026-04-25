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

%% -- parse_retry_after tests -----------------------------------------

parse_retry_after_seconds_test() ->
    Headers = [{"retry-after", "30"}],
    ?assertEqual(30, openrouter_http:parse_retry_after(Headers)).

parse_retry_after_zero_test() ->
    Headers = [{"retry-after", "0"}],
    ?assertEqual(undefined, openrouter_http:parse_retry_after(Headers)).

parse_retry_after_negative_test() ->
    Headers = [{"retry-after", "-5"}],
    ?assertEqual(undefined, openrouter_http:parse_retry_after(Headers)).

parse_retry_after_not_a_number_test() ->
    Headers = [{"retry-after", "not-a-number"}],
    ?assertEqual(undefined, openrouter_http:parse_retry_after(Headers)).

parse_retry_after_mixed_case_header_test() ->
    Headers = [{"Retry-After", "45"}],
    ?assertEqual(45, openrouter_http:parse_retry_after(Headers)).

parse_retry_after_missing_header_test() ->
    Headers = [{"content-type", "application/json"}],
    ?assertEqual(undefined, openrouter_http:parse_retry_after(Headers)).

parse_retry_after_empty_headers_test() ->
    ?assertEqual(undefined, openrouter_http:parse_retry_after([])).
