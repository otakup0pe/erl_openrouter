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

%% --- Content normalization tests (extended thinking support) ---

%% Standard binary content passes through unchanged.
content_normalization_binary_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"id">> => <<"gen-norm-1">>,
        <<"model">> => <<"anthropic/claude-3-haiku">>,
        <<"choices">> => [#{
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => <<"Hello world">>
            },
            <<"finish_reason">> => <<"stop">>
        }],
        <<"usage">> => #{}
    }),
    {ok, Response} = openrouter_chat:parse_response(Json),
    [Choice] = Response#chat_response.choices,
    ?assertEqual(<<"Hello world">>,
                 maps:get(<<"content">>, maps:get(<<"message">>, Choice))).

%% Content blocks format (extended thinking models). The text block
%% should be extracted and content normalized to a plain binary.
content_normalization_blocks_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"id">> => <<"gen-norm-2">>,
        <<"model">> => <<"anthropic/claude-sonnet-4-6">>,
        <<"choices">> => [#{
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => [
                    #{<<"type">> => <<"thinking">>,
                      <<"thinking">> => <<"Let me reason about this...">>},
                    #{<<"type">> => <<"text">>,
                      <<"text">> => <<"{\"title\": \"Result\"}">>}
                ]
            },
            <<"finish_reason">> => <<"stop">>
        }],
        <<"usage">> => #{}
    }),
    {ok, Response} = openrouter_chat:parse_response(Json),
    [Choice] = Response#chat_response.choices,
    Content = maps:get(<<"content">>, maps:get(<<"message">>, Choice)),
    ?assertEqual(<<"{\"title\": \"Result\"}">>, Content).

%% Multiple text blocks are concatenated with newline separator.
content_normalization_multiple_text_blocks_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"id">> => <<"gen-norm-3">>,
        <<"model">> => <<"test">>,
        <<"choices">> => [#{
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => [
                    #{<<"type">> => <<"text">>, <<"text">> => <<"Part 1">>},
                    #{<<"type">> => <<"text">>, <<"text">> => <<"Part 2">>}
                ]
            },
            <<"finish_reason">> => <<"stop">>
        }],
        <<"usage">> => #{}
    }),
    {ok, Response} = openrouter_chat:parse_response(Json),
    [Choice] = Response#chat_response.choices,
    Content = maps:get(<<"content">>, maps:get(<<"message">>, Choice)),
    ?assertEqual(<<"Part 1\nPart 2">>, Content).

%% Content blocks with only thinking (no text block) normalizes to null.
content_normalization_thinking_only_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"id">> => <<"gen-norm-4">>,
        <<"model">> => <<"test">>,
        <<"choices">> => [#{
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => [
                    #{<<"type">> => <<"thinking">>,
                      <<"thinking">> => <<"Internal reasoning only">>}
                ]
            },
            <<"finish_reason">> => <<"stop">>
        }],
        <<"usage">> => #{}
    }),
    {ok, Response} = openrouter_chat:parse_response(Json),
    [Choice] = Response#chat_response.choices,
    Content = maps:get(<<"content">>, maps:get(<<"message">>, Choice)),
    ?assertEqual(null, Content).

%% Null content with reasoning_content fallback field.
content_normalization_reasoning_content_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"id">> => <<"gen-norm-5">>,
        <<"model">> => <<"test">>,
        <<"choices">> => [#{
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => null,
                <<"reasoning_content">> => <<"The answer is 42.">>
            },
            <<"finish_reason">> => <<"stop">>
        }],
        <<"usage">> => #{}
    }),
    {ok, Response} = openrouter_chat:parse_response(Json),
    [Choice] = Response#chat_response.choices,
    Content = maps:get(<<"content">>, maps:get(<<"message">>, Choice)),
    ?assertEqual(<<"The answer is 42.">>, Content).

%% Null content with no fallback remains null (e.g. tool_calls response).
content_normalization_null_no_fallback_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"id">> => <<"gen-norm-6">>,
        <<"model">> => <<"test">>,
        <<"choices">> => [#{
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => null,
                <<"tool_calls">> => [#{
                    <<"id">> => <<"call_1">>,
                    <<"type">> => <<"function">>,
                    <<"function">> => #{
                        <<"name">> => <<"foo">>,
                        <<"arguments">> => <<"{}">>
                    }
                }]
            },
            <<"finish_reason">> => <<"tool_calls">>
        }],
        <<"usage">> => #{}
    }),
    {ok, Response} = openrouter_chat:parse_response(Json),
    [Choice] = Response#chat_response.choices,
    Content = maps:get(<<"content">>, maps:get(<<"message">>, Choice)),
    ?assertEqual(null, Content).

%% extract_text_content/1 helper works on a raw choice map.
extract_text_content_test() ->
    Choice = #{<<"message">> => #{
        <<"role">> => <<"assistant">>,
        <<"content">> => <<"Direct text">>
    }},
    ?assertEqual(<<"Direct text">>, openrouter_chat:extract_text_content(Choice)).

extract_text_content_blocks_test() ->
    Choice = #{<<"message">> => #{
        <<"role">> => <<"assistant">>,
        <<"content">> => [
            #{<<"type">> => <<"thinking">>, <<"thinking">> => <<"hmm">>},
            #{<<"type">> => <<"text">>, <<"text">> => <<"answer">>}
        ]
    }},
    ?assertEqual(<<"answer">>, openrouter_chat:extract_text_content(Choice)).

extract_text_content_missing_test() ->
    ?assertEqual(null, openrouter_chat:extract_text_content(#{})).
