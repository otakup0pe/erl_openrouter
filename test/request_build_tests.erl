-module(request_build_tests).
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

%% Tests that openrouter_chat:build_request/2 produces correct JSON
%% for all parameter combinations per OpenAPI spec.

minimal_request_test() ->
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}],
    Json = openrouter_chat:build_request(Messages, #{}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual([#{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}],
                 maps:get(<<"messages">>, Decoded)),
    %% No extra keys when no opts provided
    ?assertEqual(1, maps:size(Decoded)).

with_model_test() ->
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
    Json = openrouter_chat:build_request(Messages, #{model => <<"anthropic/claude-3-haiku">>}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(<<"anthropic/claude-3-haiku">>, maps:get(<<"model">>, Decoded)).

with_temperature_test() ->
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
    Json = openrouter_chat:build_request(Messages, #{temperature => 0.7}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(0.7, maps:get(<<"temperature">>, Decoded)).

with_all_sampling_params_test() ->
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
    Opts = #{
        temperature => 0.8,
        top_p => 0.9,
        top_k => 40,
        frequency_penalty => 0.5,
        presence_penalty => 0.3,
        repetition_penalty => 1.1,
        min_p => 0.05,
        top_a => 0.1,
        seed => 42,
        max_tokens => 1000
    },
    Json = openrouter_chat:build_request(Messages, Opts),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(0.8, maps:get(<<"temperature">>, Decoded)),
    ?assertEqual(0.9, maps:get(<<"top_p">>, Decoded)),
    ?assertEqual(40, maps:get(<<"top_k">>, Decoded)),
    ?assertEqual(0.5, maps:get(<<"frequency_penalty">>, Decoded)),
    ?assertEqual(0.3, maps:get(<<"presence_penalty">>, Decoded)),
    ?assertEqual(1.1, maps:get(<<"repetition_penalty">>, Decoded)),
    ?assertEqual(0.05, maps:get(<<"min_p">>, Decoded)),
    ?assertEqual(0.1, maps:get(<<"top_a">>, Decoded)),
    ?assertEqual(42, maps:get(<<"seed">>, Decoded)),
    ?assertEqual(1000, maps:get(<<"max_tokens">>, Decoded)).

with_stop_sequences_test() ->
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
    Json = openrouter_chat:build_request(Messages, #{stop => [<<"END">>, <<"STOP">>]}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual([<<"END">>, <<"STOP">>], maps:get(<<"stop">>, Decoded)).

with_response_format_test() ->
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
    Format = #{<<"type">> => <<"json_object">>},
    Json = openrouter_chat:build_request(Messages, #{response_format => Format}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(Format, maps:get(<<"response_format">>, Decoded)).

with_tools_test() ->
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
    Tool = #{
        <<"type">> => <<"function">>,
        <<"function">> => #{
            <<"name">> => <<"get_weather">>,
            <<"parameters">> => #{<<"type">> => <<"object">>}
        }
    },
    Json = openrouter_chat:build_request(Messages, #{tools => [Tool], tool_choice => <<"auto">>}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual([Tool], maps:get(<<"tools">>, Decoded)),
    ?assertEqual(<<"auto">>, maps:get(<<"tool_choice">>, Decoded)).

multi_message_conversation_test() ->
    Messages = [
        #{<<"role">> => <<"system">>, <<"content">> => <<"You are helpful.">>},
        #{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>},
        #{<<"role">> => <<"assistant">>, <<"content">> => <<"Hi there!">>},
        #{<<"role">> => <<"user">>, <<"content">> => <<"How are you?">>}
    ],
    Json = openrouter_chat:build_request(Messages, #{}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(4, length(maps:get(<<"messages">>, Decoded))).

undefined_opts_excluded_test() ->
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
    %% Explicitly pass undefined values -- they should not appear in JSON
    Opts = #{model => <<"test">>, temperature => undefined},
    Json = openrouter_chat:build_request(Messages, Opts),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assert(maps:is_key(<<"model">>, Decoded)),
    ?assertNot(maps:is_key(<<"temperature">>, Decoded)).

with_provider_test() ->
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
    Provider = #{<<"ignore">> => [<<"deepinfra">>]},
    Json = openrouter_chat:build_request(Messages, #{provider => Provider}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertEqual(Provider, maps:get(<<"provider">>, Decoded)).

provider_omitted_when_absent_test() ->
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
    Json = openrouter_chat:build_request(Messages, #{model => <<"test">>}),
    {ok, Decoded} = openrouter_json:decode(Json),
    ?assertNot(maps:is_key(<<"provider">>, Decoded)).

output_is_binary_test() ->
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
    Json = openrouter_chat:build_request(Messages, #{}),
    ?assert(is_binary(Json)).
