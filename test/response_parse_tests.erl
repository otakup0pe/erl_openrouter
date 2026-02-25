-module(response_parse_tests).
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

%% Tests that openrouter_chat:parse_response/1 correctly parses
%% success and error responses per OpenAPI spec.

success_response_test() ->
    Body = openrouter_json:encode(#{
        <<"id">> => <<"gen-abc123">>,
        <<"model">> => <<"anthropic/claude-3-haiku">>,
        <<"choices">> => [#{
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => <<"Hello!">>
            },
            <<"finish_reason">> => <<"stop">>
        }],
        <<"usage">> => #{
            <<"prompt_tokens">> => 10,
            <<"completion_tokens">> => 5,
            <<"total_tokens">> => 15
        }
    }),
    {ok, Json} = Body,
    {ok, Response} = openrouter_chat:parse_response(Json),
    ?assertEqual(<<"gen-abc123">>, Response#chat_response.id),
    ?assertEqual(<<"anthropic/claude-3-haiku">>, Response#chat_response.model),
    ?assertEqual(1, length(Response#chat_response.choices)),
    ?assertEqual(15, maps:get(<<"total_tokens">>, Response#chat_response.usage)).

response_with_cost_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"id">> => <<"gen-xyz">>,
        <<"model">> => <<"openai/gpt-4">>,
        <<"choices">> => [#{
            <<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => <<"Hi">>},
            <<"finish_reason">> => <<"stop">>
        }],
        <<"usage">> => #{<<"prompt_tokens">> => 5, <<"completion_tokens">> => 2, <<"total_tokens">> => 7},
        <<"cost">> => 0.00015
    }),
    {ok, Response} = openrouter_chat:parse_response(Json),
    ?assertEqual(0.00015, Response#chat_response.cost).

response_missing_optional_fields_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"id">> => <<"gen-minimal">>,
        <<"choices">> => []
    }),
    {ok, Response} = openrouter_chat:parse_response(Json),
    ?assertEqual(<<"gen-minimal">>, Response#chat_response.id),
    ?assertEqual(undefined, Response#chat_response.model),
    ?assertEqual([], Response#chat_response.choices),
    ?assertEqual(#{}, Response#chat_response.usage),
    ?assertEqual(undefined, Response#chat_response.cost).

error_in_body_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"error">> => #{
            <<"code">> => 429,
            <<"message">> => <<"Rate limit exceeded">>
        }
    }),
    {error, ApiError} = openrouter_chat:parse_response(Json),
    ?assertEqual(rate_limited, ApiError#api_error.type),
    ?assertEqual(<<"Rate limit exceeded">>, ApiError#api_error.message).

invalid_json_test() ->
    {error, {parse_error, _}} = openrouter_chat:parse_response(<<"not json">>).

multiple_choices_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"id">> => <<"gen-multi">>,
        <<"model">> => <<"test">>,
        <<"choices">> => [
            #{<<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => <<"A">>},
              <<"finish_reason">> => <<"stop">>},
            #{<<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => <<"B">>},
              <<"finish_reason">> => <<"stop">>}
        ],
        <<"usage">> => #{<<"prompt_tokens">> => 10, <<"completion_tokens">> => 4, <<"total_tokens">> => 14}
    }),
    {ok, Response} = openrouter_chat:parse_response(Json),
    ?assertEqual(2, length(Response#chat_response.choices)).

tool_call_response_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"id">> => <<"gen-tool">>,
        <<"model">> => <<"test">>,
        <<"choices">> => [#{
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => null,
                <<"tool_calls">> => [#{
                    <<"id">> => <<"call_1">>,
                    <<"type">> => <<"function">>,
                    <<"function">> => #{
                        <<"name">> => <<"get_weather">>,
                        <<"arguments">> => <<"{\"city\":\"NYC\"}">>
                    }
                }]
            },
            <<"finish_reason">> => <<"tool_calls">>
        }],
        <<"usage">> => #{<<"prompt_tokens">> => 20, <<"completion_tokens">> => 15, <<"total_tokens">> => 35}
    }),
    {ok, Response} = openrouter_chat:parse_response(Json),
    [Choice] = Response#chat_response.choices,
    Message = maps:get(<<"message">>, Choice),
    [ToolCall] = maps:get(<<"tool_calls">>, Message),
    ?assertEqual(<<"get_weather">>,
                 maps:get(<<"name">>, maps:get(<<"function">>, ToolCall))).
