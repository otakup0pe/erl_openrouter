-module(tool_use_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

%% End-to-end tool-use tests against the mock OpenRouter server.
%% Covers non-streaming request/response, follow-up tool messages,
%% parallel tool calls, malformed-response handling, duplicate-tool
%% validation, and the extra-headers plumbing (Anthropic beta).

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    request_with_tools_encoded/1,
    request_with_tool_choice_specific/1,
    request_with_tool_choice_auto/1,
    empty_tools_suppressed/1,
    tool_calls_response_parsed/1,
    parallel_tool_calls_response/1,
    follow_up_tool_result_message/1,
    malformed_tool_calls_response/1,
    duplicate_tool_name_rejected/1,
    extra_headers_flow_through/1
]).

all() -> [{group, tool_use}].

groups() ->
    [{tool_use, [sequence], [
        request_with_tools_encoded,
        request_with_tool_choice_specific,
        request_with_tool_choice_auto,
        empty_tools_suppressed,
        tool_calls_response_parsed,
        parallel_tool_calls_response,
        follow_up_tool_result_message,
        malformed_tool_calls_response,
        duplicate_tool_name_rejected,
        extra_headers_flow_through
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
    [{base_url, BaseUrl} | Config].

end_per_testcase(_TC, _Config) ->
    case whereis(openrouter_client) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end,
    mock_openrouter:stop(),
    application:unset_env(erl_openrouter, api_key).

%% Helpers

start_client(BaseUrl) ->
    start_client(BaseUrl, #{}).

start_client(BaseUrl, Extra) ->
    Opts = maps:merge(#{base_url => BaseUrl,
                        auth_callback => fun() -> {ok, <<"sk-test-key">>} end},
                      Extra),
    {ok, Pid} = openrouter_client:start_link(Opts),
    unlink(Pid),
    Pid.

weather_tool() ->
    #tool{function = #tool_function{
        name = <<"get_weather">>,
        description = <<"Get weather for a city">>,
        parameters = #{<<"type">> => <<"object">>,
                       <<"properties">> => #{
                           <<"city">> => #{<<"type">> => <<"string">>}
                       }}
    }}.

time_tool() ->
    #tool{function = #tool_function{
        name = <<"get_time">>,
        description = <<"Get current time">>,
        parameters = #{<<"type">> => <<"object">>, <<"properties">> => #{}}
    }}.

%% Tests

request_with_tools_encoded(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    _ = start_client(BaseUrl),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Weather?">>}],
    {ok, _} = openrouter:chat(Messages, #{tools => [weather_tool()]}),
    #{body := ReqBody} = mock_openrouter:last_request(),
    {ok, Decoded} = openrouter_json:decode(ReqBody),
    Tools = maps:get(<<"tools">>, Decoded),
    ?assertEqual(1, length(Tools)),
    [Tool] = Tools,
    ?assertEqual(<<"function">>, maps:get(<<"type">>, Tool)),
    Fun = maps:get(<<"function">>, Tool),
    ?assertEqual(<<"get_weather">>, maps:get(<<"name">>, Fun)),
    ?assertEqual(<<"Get weather for a city">>, maps:get(<<"description">>, Fun)),
    ?assert(is_map(maps:get(<<"parameters">>, Fun))).

request_with_tool_choice_specific(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    _ = start_client(BaseUrl),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}],
    {ok, _} = openrouter:chat(Messages, #{
        tools => [weather_tool()],
        tool_choice => {function, <<"get_weather">>}
    }),
    #{body := ReqBody} = mock_openrouter:last_request(),
    {ok, Decoded} = openrouter_json:decode(ReqBody),
    Choice = maps:get(<<"tool_choice">>, Decoded),
    ?assertEqual(<<"function">>, maps:get(<<"type">>, Choice)),
    ?assertEqual(<<"get_weather">>,
                 maps:get(<<"name">>, maps:get(<<"function">>, Choice))).

request_with_tool_choice_auto(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    _ = start_client(BaseUrl),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}],
    {ok, _} = openrouter:chat(Messages, #{
        tools => [weather_tool()],
        tool_choice => auto
    }),
    #{body := ReqBody} = mock_openrouter:last_request(),
    {ok, Decoded} = openrouter_json:decode(ReqBody),
    ?assertEqual(<<"auto">>, maps:get(<<"tool_choice">>, Decoded)).

empty_tools_suppressed(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    _ = start_client(BaseUrl),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}],
    {ok, _} = openrouter:chat(Messages, #{tools => []}),
    #{body := ReqBody} = mock_openrouter:last_request(),
    {ok, Decoded} = openrouter_json:decode(ReqBody),
    ?assertNot(maps:is_key(<<"tools">>, Decoded)).

tool_calls_response_parsed(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    _ = start_client(BaseUrl),
    {ok, Body} = openrouter_json:encode(#{
        <<"id">> => <<"gen-1">>,
        <<"model">> => <<"openai/gpt-4">>,
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
        <<"usage">> => #{<<"prompt_tokens">> => 10, <<"completion_tokens">> => 5,
                         <<"total_tokens">> => 15}
    }),
    mock_openrouter:set_response({200, Body}),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Weather?">>}],
    {ok, Response} = openrouter:chat(Messages, #{tools => [weather_tool()]}),
    [Choice] = Response#chat_response.choices,
    FR = openrouter_chat:classify_finish_reason(
           maps:get(<<"finish_reason">>, Choice)),
    ?assertEqual(tool_calls, FR),
    [RawCall] = maps:get(<<"tool_calls">>,
                         maps:get(<<"message">>, Choice)),
    TC = openrouter_tools:decode_tool_call(RawCall),
    ?assertEqual(<<"call_1">>, TC#tool_call.id),
    ?assertEqual(<<"get_weather">>, TC#tool_call.function_name),
    ?assertEqual(<<"{\"city\":\"NYC\"}">>, TC#tool_call.function_arguments).

parallel_tool_calls_response(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    _ = start_client(BaseUrl),
    {ok, Body} = openrouter_json:encode(#{
        <<"id">> => <<"gen-p">>,
        <<"model">> => <<"openai/gpt-4">>,
        <<"choices">> => [#{
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => null,
                <<"tool_calls">> => [
                    #{<<"id">> => <<"call_a">>, <<"type">> => <<"function">>,
                      <<"function">> => #{<<"name">> => <<"get_weather">>,
                                          <<"arguments">> => <<"{\"city\":\"NYC\"}">>}},
                    #{<<"id">> => <<"call_b">>, <<"type">> => <<"function">>,
                      <<"function">> => #{<<"name">> => <<"get_time">>,
                                          <<"arguments">> => <<"{}">>}}
                ]
            },
            <<"finish_reason">> => <<"tool_calls">>
        }],
        <<"usage">> => #{<<"prompt_tokens">> => 10, <<"completion_tokens">> => 5,
                         <<"total_tokens">> => 15}
    }),
    mock_openrouter:set_response({200, Body}),
    {ok, Response} = openrouter:chat(
        [#{<<"role">> => <<"user">>, <<"content">> => <<"both">>}],
        #{tools => [weather_tool(), time_tool()]}),
    [Choice] = Response#chat_response.choices,
    Raws = maps:get(<<"tool_calls">>, maps:get(<<"message">>, Choice)),
    TCs = openrouter_tools:decode_tool_calls(Raws),
    ?assertEqual(2, length(TCs)),
    %% Correlate by id, not by position.
    ById = maps:from_list([{TC#tool_call.id, TC} || TC <- TCs]),
    ?assertEqual(<<"get_weather">>,
                 (maps:get(<<"call_a">>, ById))#tool_call.function_name),
    ?assertEqual(<<"get_time">>,
                 (maps:get(<<"call_b">>, ById))#tool_call.function_name).

follow_up_tool_result_message(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    _ = start_client(BaseUrl),
    %% Caller builds a follow-up request with a role=tool message.
    ToolMsg = openrouter_tools:encode_tool_result_message(
        <<"call_1">>, <<"{\"temp\":72}">>),
    Messages = [
        #{<<"role">> => <<"user">>, <<"content">> => <<"Weather?">>},
        #{<<"role">> => <<"assistant">>,
          <<"content">> => null,
          <<"tool_calls">> => [#{
              <<"id">> => <<"call_1">>,
              <<"type">> => <<"function">>,
              <<"function">> => #{<<"name">> => <<"get_weather">>,
                                   <<"arguments">> => <<"{\"city\":\"NYC\"}">>}
          }]},
        ToolMsg
    ],
    {ok, _} = openrouter:chat(Messages),
    #{body := ReqBody} = mock_openrouter:last_request(),
    {ok, Decoded} = openrouter_json:decode(ReqBody),
    SentMsgs = maps:get(<<"messages">>, Decoded),
    ?assertEqual(3, length(SentMsgs)),
    ToolSent = lists:last(SentMsgs),
    ?assertEqual(<<"tool">>, maps:get(<<"role">>, ToolSent)),
    ?assertEqual(<<"call_1">>, maps:get(<<"tool_call_id">>, ToolSent)),
    %% Content preserved as raw binary
    ?assertEqual(<<"{\"temp\":72}">>, maps:get(<<"content">>, ToolSent)).

malformed_tool_calls_response(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    _ = start_client(BaseUrl),
    %% finish_reason=tool_calls but no tool_calls field on message
    {ok, Body} = openrouter_json:encode(#{
        <<"id">> => <<"gen-m">>,
        <<"model">> => <<"x">>,
        <<"choices">> => [#{
            <<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => null},
            <<"finish_reason">> => <<"tool_calls">>
        }],
        <<"usage">> => #{<<"prompt_tokens">> => 1, <<"completion_tokens">> => 0,
                         <<"total_tokens">> => 1}
    }),
    mock_openrouter:set_response({200, Body}),
    Result = openrouter:chat(
        [#{<<"role">> => <<"user">>, <<"content">> => <<"x">>}]),
    ?assertMatch({error, #api_error{type = malformed_response}}, Result).

duplicate_tool_name_rejected(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    _ = start_client(BaseUrl),
    Dup = weather_tool(),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}],
    %% The client catches the duplicate-tool error narrowly and
    %% returns {error, {duplicate_tool_name, Name}} without crashing
    %% the gen_server.
    ?assertEqual({error, {duplicate_tool_name, <<"get_weather">>}},
                 openrouter:chat(Messages, #{tools => [Dup, Dup]})),
    %% And the client is still alive for the next test.
    ?assertNotEqual(undefined, whereis(openrouter_client)).

extra_headers_flow_through(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    _ = start_client(BaseUrl, #{
        extra_headers => [{"X-Anthropic-Beta", "structured-outputs-2025-11-13"}]
    }),
    {ok, _} = openrouter:chat(
        [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]),
    #{headers := Headers} = mock_openrouter:last_request(),
    Seen = maps:get(<<"x-anthropic-beta">>, Headers, undefined),
    ?assertEqual(<<"structured-outputs-2025-11-13">>, Seen).

