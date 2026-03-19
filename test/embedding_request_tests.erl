-module(embedding_request_tests).
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

%% Tests that openrouter_embeddings:build_request/2 produces correct JSON
%% for the OpenRouter /api/v1/embeddings endpoint.

minimal_request_test() ->
    Input = <<"hello world">>,
    Json = openrouter_embeddings:build_request(Input, #{}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(<<"hello world">>, maps:get(<<"input">>, Decoded)),
    ?assertEqual(1, maps:size(Decoded)).

with_model_test() ->
    Input = <<"test input">>,
    Json = openrouter_embeddings:build_request(Input,
        #{model => <<"openai/text-embedding-3-small">>}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(<<"openai/text-embedding-3-small">>,
                 maps:get(<<"model">>, Decoded)),
    ?assertEqual(<<"test input">>, maps:get(<<"input">>, Decoded)).

with_dimensions_test() ->
    Input = <<"test">>,
    Json = openrouter_embeddings:build_request(Input,
        #{model => <<"openai/text-embedding-3-small">>,
          dimensions => 768}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(768, maps:get(<<"dimensions">>, Decoded)).

with_encoding_format_test() ->
    Input = <<"test">>,
    Json = openrouter_embeddings:build_request(Input,
        #{encoding_format => <<"float">>}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(<<"float">>, maps:get(<<"encoding_format">>, Decoded)).

batch_input_test() ->
    Input = [<<"first">>, <<"second">>, <<"third">>],
    Json = openrouter_embeddings:build_request(Input, #{}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual([<<"first">>, <<"second">>, <<"third">>],
                 maps:get(<<"input">>, Decoded)).

undefined_opts_excluded_test() ->
    Input = <<"test">>,
    Opts = #{model => <<"test-model">>, dimensions => undefined},
    Json = openrouter_embeddings:build_request(Input, Opts),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assert(maps:is_key(<<"model">>, Decoded)),
    ?assertNot(maps:is_key(<<"dimensions">>, Decoded)).

output_is_binary_test() ->
    Json = openrouter_embeddings:build_request(<<"hi">>, #{}),
    ?assert(is_binary(Json)).

all_opts_test() ->
    Input = <<"full test">>,
    Opts = #{
        model => <<"openai/text-embedding-3-large">>,
        dimensions => 3072,
        encoding_format => <<"float">>
    },
    Json = openrouter_embeddings:build_request(Input, Opts),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(<<"full test">>, maps:get(<<"input">>, Decoded)),
    ?assertEqual(<<"openai/text-embedding-3-large">>, maps:get(<<"model">>, Decoded)),
    ?assertEqual(3072, maps:get(<<"dimensions">>, Decoded)),
    ?assertEqual(<<"float">>, maps:get(<<"encoding_format">>, Decoded)),
    ?assertEqual(4, maps:size(Decoded)).
