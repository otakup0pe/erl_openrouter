-module(chat_completions_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    simple_chat_request/1,
    chat_with_model_selection/1,
    chat_with_all_params/1,
    chat_request_headers_correct/1,
    chat_request_body_structure/1,
    chat_response_parsed_correctly/1,
    chat_with_tool_calls_response/1,
    chat_with_cost_tracking/1
]).

all() -> [{group, chat_completions}].

groups() ->
    [{chat_completions, [sequence], [
        simple_chat_request,
        chat_with_model_selection,
        chat_with_all_params,
        chat_request_headers_correct,
        chat_request_body_structure,
        chat_response_parsed_correctly,
        chat_with_tool_calls_response,
        chat_with_cost_tracking
    ]}].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    ok = mock_openrouter:start(),
    Port = mock_openrouter:port(),
    BaseUrl = "http://localhost:" ++ integer_to_list(Port) ++ "/api/v1",
    application:set_env(erl_openrouter, api_key, <<"sk-test-key">>),
    application:set_env(erl_openrouter, base_url, BaseUrl),
    {ok, Pid} = openrouter_client:start_link(#{
        base_url => BaseUrl,
        auth_callback => fun() -> {ok, <<"sk-test-key">>} end
    }),
    unlink(Pid),
    [{client_pid, Pid}, {base_url, BaseUrl} | Config].

end_per_testcase(_TC, Config) ->
    Pid = proplists:get_value(client_pid, Config),
    gen_server:stop(Pid),
    mock_openrouter:stop(),
    application:unset_env(erl_openrouter, api_key).

%% Tests

simple_chat_request(Config) ->
    _BaseUrl = proplists:get_value(base_url, Config),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}],
    {ok, Response} = openrouter:chat(Messages),
    ?assertMatch(#chat_response{}, Response),
    ?assertEqual(<<"gen-mock-001">>, Response#chat_response.id).

chat_with_model_selection(_Config) ->
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}],
    {ok, _Response} = openrouter:chat(Messages, #{model => <<"anthropic/claude-3-haiku">>}),
    #{body := ReqBody} = mock_openrouter:last_request(),
    {ok, Decoded} = openrouter_json:decode(ReqBody),
    ?assertEqual(<<"anthropic/claude-3-haiku">>, maps:get(<<"model">>, Decoded)).

chat_with_all_params(_Config) ->
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}],
    Opts = #{
        model => <<"test/model">>,
        temperature => 0.7,
        max_tokens => 500,
        top_p => 0.9
    },
    {ok, _} = openrouter:chat(Messages, Opts),
    #{body := ReqBody} = mock_openrouter:last_request(),
    {ok, Decoded} = openrouter_json:decode(ReqBody),
    ?assertEqual(0.7, maps:get(<<"temperature">>, Decoded)),
    ?assertEqual(500, maps:get(<<"max_tokens">>, Decoded)),
    ?assertEqual(0.9, maps:get(<<"top_p">>, Decoded)).

chat_request_headers_correct(_Config) ->
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}],
    {ok, _} = openrouter:chat(Messages),
    #{headers := Headers} = mock_openrouter:last_request(),
    AuthHeader = maps:get(<<"authorization">>, Headers),
    ?assertEqual(<<"Bearer sk-test-key">>, AuthHeader).

chat_request_body_structure(_Config) ->
    Messages = [
        #{<<"role">> => <<"system">>, <<"content">> => <<"Be helpful">>},
        #{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}
    ],
    {ok, _} = openrouter:chat(Messages),
    #{body := ReqBody} = mock_openrouter:last_request(),
    {ok, Decoded} = openrouter_json:decode(ReqBody),
    DecodedMessages = maps:get(<<"messages">>, Decoded),
    ?assertEqual(2, length(DecodedMessages)),
    [SysMsg, UserMsg] = DecodedMessages,
    ?assertEqual(<<"system">>, maps:get(<<"role">>, SysMsg)),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, UserMsg)).

chat_response_parsed_correctly(_Config) ->
    {ok, CustomBody} = openrouter_json:encode(#{
        <<"id">> => <<"gen-custom-123">>,
        <<"model">> => <<"anthropic/claude-3-opus">>,
        <<"choices">> => [#{
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => <<"Custom response content">>
            },
            <<"finish_reason">> => <<"stop">>
        }],
        <<"usage">> => #{
            <<"prompt_tokens">> => 25,
            <<"completion_tokens">> => 10,
            <<"total_tokens">> => 35
        },
        <<"cost">> => 0.001
    }),
    mock_openrouter:set_response({200, CustomBody}),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}],
    {ok, Response} = openrouter:chat(Messages),
    ?assertEqual(<<"gen-custom-123">>, Response#chat_response.id),
    ?assertEqual(<<"anthropic/claude-3-opus">>, Response#chat_response.model),
    ?assertEqual(35, maps:get(<<"total_tokens">>, Response#chat_response.usage)),
    ?assertEqual(0.001, Response#chat_response.cost).

chat_with_tool_calls_response(_Config) ->
    {ok, ToolBody} = openrouter_json:encode(#{
        <<"id">> => <<"gen-tool-001">>,
        <<"model">> => <<"openai/gpt-4">>,
        <<"choices">> => [#{
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => null,
                <<"tool_calls">> => [#{
                    <<"id">> => <<"call_abc">>,
                    <<"type">> => <<"function">>,
                    <<"function">> => #{
                        <<"name">> => <<"get_weather">>,
                        <<"arguments">> => <<"{\"city\":\"London\"}">>
                    }
                }]
            },
            <<"finish_reason">> => <<"tool_calls">>
        }],
        <<"usage">> => #{<<"prompt_tokens">> => 30, <<"completion_tokens">> => 20, <<"total_tokens">> => 50}
    }),
    mock_openrouter:set_response({200, ToolBody}),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Weather?">>}],
    {ok, Response} = openrouter:chat(Messages),
    [Choice] = Response#chat_response.choices,
    Msg = maps:get(<<"message">>, Choice),
    ?assertEqual(<<"tool_calls">>, maps:get(<<"finish_reason">>, Choice)),
    [ToolCall] = maps:get(<<"tool_calls">>, Msg),
    ?assertEqual(<<"get_weather">>,
                 maps:get(<<"name">>, maps:get(<<"function">>, ToolCall))).

chat_with_cost_tracking(_Config) ->
    {ok, CostBody} = openrouter_json:encode(#{
        <<"id">> => <<"gen-cost">>,
        <<"model">> => <<"test">>,
        <<"choices">> => [#{
            <<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => <<"ok">>},
            <<"finish_reason">> => <<"stop">>
        }],
        <<"usage">> => #{<<"prompt_tokens">> => 5, <<"completion_tokens">> => 2, <<"total_tokens">> => 7},
        <<"cost">> => 0.00003
    }),
    mock_openrouter:set_response({200, CostBody}),
    {ok, Response} = openrouter:chat([#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]),
    ?assertEqual(0.00003, Response#chat_response.cost).
