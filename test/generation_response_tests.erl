-module(generation_response_tests).
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

%% Unit tests for openrouter_generation:parse_response/1.

success_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"data">> => #{
            <<"id">> => <<"gen-abc123">>,
            <<"total_cost">> => 0.0012,
            <<"latency">> => 1234,
            <<"generation_time">> => 987,
            <<"provider_name">> => <<"OpenAI">>,
            <<"tokens_prompt">> => 50,
            <<"tokens_completion">> => 25,
            <<"provider_responses">> => [
                #{<<"latency">> => 1200, <<"status">> => <<"success">>}
            ]
        }
    }),
    {ok, Data} = openrouter_generation:parse_response(Json),
    ?assertEqual(<<"gen-abc123">>, maps:get(<<"id">>, Data)),
    ?assertEqual(0.0012, maps:get(<<"total_cost">>, Data)),
    ?assertEqual(1234, maps:get(<<"latency">>, Data)),
    ?assertEqual(987, maps:get(<<"generation_time">>, Data)),
    ?assertEqual(<<"OpenAI">>, maps:get(<<"provider_name">>, Data)),
    ?assertEqual(50, maps:get(<<"tokens_prompt">>, Data)),
    ?assertEqual(25, maps:get(<<"tokens_completion">>, Data)).

error_in_body_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"error">> => #{
            <<"code">> => 401,
            <<"message">> => <<"Invalid API key">>
        }
    }),
    {error, Error} = openrouter_generation:parse_response(Json),
    ?assertEqual(auth_error, Error#api_error.type),
    ?assertEqual(<<"Invalid API key">>, Error#api_error.message).

unexpected_json_test() ->
    {ok, Json} = openrouter_json:encode(#{<<"something">> => <<"else">>}),
    ?assertMatch({error, {unexpected_response, _}},
                 openrouter_generation:parse_response(Json)).

html_error_page_test() ->
    Html = <<"<html><body>502 Bad Gateway</body></html>">>,
    {error, {parse_error, #{raw_body := RawBody}}} =
        openrouter_generation:parse_response(Html),
    ?assertEqual(Html, RawBody).

provider_responses_present_test() ->
    ProviderResponses = [
        #{<<"latency">> => 800, <<"status">> => <<"success">>,
          <<"model">> => <<"gpt-4">>},
        #{<<"latency">> => 1200, <<"status">> => <<"failure">>,
          <<"model">> => <<"gpt-4">>}
    ],
    {ok, Json} = openrouter_json:encode(#{
        <<"data">> => #{
            <<"id">> => <<"gen-xyz789">>,
            <<"total_cost">> => 0.005,
            <<"latency">> => 2000,
            <<"generation_time">> => 1500,
            <<"provider_name">> => <<"OpenAI">>,
            <<"tokens_prompt">> => 100,
            <<"tokens_completion">> => 50,
            <<"provider_responses">> => ProviderResponses
        }
    }),
    {ok, Data} = openrouter_generation:parse_response(Json),
    Responses = maps:get(<<"provider_responses">>, Data),
    ?assertEqual(2, length(Responses)),
    [First | _] = Responses,
    ?assertEqual(800, maps:get(<<"latency">>, First)),
    ?assertEqual(<<"success">>, maps:get(<<"status">>, First)).
