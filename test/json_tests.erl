-module(json_tests).
-include_lib("eunit/include/eunit.hrl").

%% Unit tests for openrouter_json encode/decode.

encode_map_test() ->
    {ok, Json} = openrouter_json:encode(#{<<"key">> => <<"value">>}),
    ?assert(is_binary(Json)),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(<<"value">>, maps:get(<<"key">>, Decoded)).

encode_nested_map_test() ->
    Input = #{<<"outer">> => #{<<"inner">> => 42}},
    {ok, Json} = openrouter_json:encode(Input),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(42, maps:get(<<"inner">>, maps:get(<<"outer">>, Decoded))).

encode_list_test() ->
    Input = #{<<"items">> => [1, 2, 3]},
    {ok, Json} = openrouter_json:encode(Input),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual([1, 2, 3], maps:get(<<"items">>, Decoded)).

encode_boolean_test() ->
    {ok, Json} = openrouter_json:encode(#{<<"flag">> => true}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(true, maps:get(<<"flag">>, Decoded)).

encode_null_test() ->
    {ok, Json} = openrouter_json:encode(#{<<"val">> => null}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(null, maps:get(<<"val">>, Decoded)).

encode_float_test() ->
    {ok, Json} = openrouter_json:encode(#{<<"pi">> => 3.14159}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assert(abs(3.14159 - maps:get(<<"pi">>, Decoded)) < 0.0001).

decode_invalid_json_test() ->
    ?assertMatch({error, {parse_error, _}}, openrouter_json:decode(<<"not json">>)).

decode_empty_string_test() ->
    ?assertMatch({error, {parse_error, _}}, openrouter_json:decode(<<>>)).

decode_truncated_json_test() ->
    ?assertMatch({error, {parse_error, _}}, openrouter_json:decode(<<"{\"key\":">>)).

roundtrip_complex_test() ->
    Input = #{
        <<"messages">> => [
            #{<<"role">> => <<"system">>, <<"content">> => <<"You are helpful.">>},
            #{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}
        ],
        <<"model">> => <<"test/model">>,
        <<"temperature">> => 0.7,
        <<"max_tokens">> => 1000,
        <<"stream">> => false
    },
    {ok, Json} = openrouter_json:encode(Input),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(<<"test/model">>, maps:get(<<"model">>, Decoded)),
    ?assertEqual(0.7, maps:get(<<"temperature">>, Decoded)),
    ?assertEqual(1000, maps:get(<<"max_tokens">>, Decoded)),
    ?assertEqual(false, maps:get(<<"stream">>, Decoded)),
    ?assertEqual(2, length(maps:get(<<"messages">>, Decoded))).

encode_returns_binary_test() ->
    {ok, Result} = openrouter_json:encode(#{<<"a">> => 1}),
    ?assert(is_binary(Result)).
