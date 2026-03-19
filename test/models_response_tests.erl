-module(models_response_tests).
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

%% Unit tests for openrouter_models:parse_response/1.

success_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"data">> => [
            #{<<"id">> => <<"openai/gpt-4">>, <<"name">> => <<"GPT-4">>},
            #{<<"id">> => <<"anthropic/claude-3-opus">>, <<"name">> => <<"Claude 3 Opus">>}
        ]
    }),
    {ok, Models} = openrouter_models:parse_response(Json),
    ?assertEqual(2, length(Models)),
    [First, _Second] = Models,
    ?assert(maps:is_key(<<"id">>, First)).

success_with_pricing_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"data">> => [
            #{<<"id">> => <<"test/model">>,
              <<"pricing">> => #{<<"prompt">> => <<"0.001">>, <<"completion">> => <<"0.002">>},
              <<"context_length">> => 128000}
        ]
    }),
    {ok, [Model]} = openrouter_models:parse_response(Json),
    ?assertEqual(<<"test/model">>, maps:get(<<"id">>, Model)),
    ?assertEqual(128000, maps:get(<<"context_length">>, Model)).

empty_list_test() ->
    {ok, Json} = openrouter_json:encode(#{<<"data">> => []}),
    {ok, Models} = openrouter_models:parse_response(Json),
    ?assertEqual([], Models).

error_in_body_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"error">> => #{
            <<"code">> => 401,
            <<"message">> => <<"Invalid API key">>
        }
    }),
    {error, Error} = openrouter_models:parse_response(Json),
    ?assertEqual(auth_error, Error#api_error.type).

missing_data_field_test() ->
    {ok, Json} = openrouter_json:encode(#{<<"models">> => []}),
    ?assertEqual({error, {parse_error, missing_data_field}},
                 openrouter_models:parse_response(Json)).

invalid_json_test() ->
    ?assertMatch({error, {parse_error, _}},
                 openrouter_models:parse_response(<<"not json">>)).
