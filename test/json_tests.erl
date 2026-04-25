-module(json_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tests for openrouter_json's error normalization. We trust the
%% underlying JSON library (OTP json / jsx) for encode/decode
%% correctness -- these tests verify OUR wrapper behavior:
%% consistent {error, {parse_error, _}} on bad input.

decode_invalid_json_test() ->
    ?assertMatch({error, {parse_error, _}}, openrouter_json:decode(<<"not json">>)).

decode_empty_string_test() ->
    ?assertMatch({error, {parse_error, _}}, openrouter_json:decode(<<>>)).

decode_truncated_json_test() ->
    ?assertMatch({error, {parse_error, _}}, openrouter_json:decode(<<"{\"key\":">>)).

encode_unencodable_term_test() ->
    ?assertMatch({error, {parse_error, {badarg, _}}},
                 openrouter_json:encode(self())).

%% Smoke test: encode produces a binary, decode round-trips it.
%% One test, not a full encode/decode matrix.
smoke_roundtrip_test() ->
    {ok, Json} = openrouter_json:encode(#{<<"k">> => <<"v">>}),
    ?assert(is_binary(Json)),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(<<"v">>, maps:get(<<"k">>, Decoded)).
