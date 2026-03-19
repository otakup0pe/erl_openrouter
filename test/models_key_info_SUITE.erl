-module(models_key_info_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    models_success/1,
    models_returns_list/1,
    models_auth_error/1,
    models_server_error/1,
    key_info_success/1,
    key_info_returns_data/1,
    key_info_auth_error/1
]).

all() -> [{group, models}, {group, key_info}].

groups() ->
    [{models, [sequence], [
        models_success,
        models_returns_list,
        models_auth_error,
        models_server_error
    ]},
    {key_info, [sequence], [
        key_info_success,
        key_info_returns_data,
        key_info_auth_error
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
    {ok, Pid} = openrouter_client:start_link(#{
        base_url => BaseUrl,
        auth_callback => fun() -> {ok, <<"sk-test-key">>} end,
        max_retries => 0
    }),
    unlink(Pid),
    [{client_pid, Pid}, {base_url, BaseUrl} | Config].

end_per_testcase(_TC, Config) ->
    Pid = proplists:get_value(client_pid, Config),
    gen_server:stop(Pid),
    mock_openrouter:stop().

%% Models tests

models_success(_Config) ->
    {ok, ModelsBody} = openrouter_json:encode(#{
        <<"data">> => [
            #{<<"id">> => <<"openai/gpt-4">>, <<"name">> => <<"GPT-4">>},
            #{<<"id">> => <<"anthropic/claude-3-opus">>, <<"name">> => <<"Claude 3 Opus">>}
        ]
    }),
    mock_openrouter:set_response(models, {200, ModelsBody}),
    {ok, Models} = openrouter:models(),
    ?assertEqual(2, length(Models)).

models_returns_list(_Config) ->
    {ok, ModelsBody} = openrouter_json:encode(#{
        <<"data">> => [
            #{<<"id">> => <<"test/model-1">>,
              <<"pricing">> => #{<<"prompt">> => <<"0.001">>, <<"completion">> => <<"0.002">>},
              <<"context_length">> => 4096}
        ]
    }),
    mock_openrouter:set_response(models, {200, ModelsBody}),
    {ok, [Model]} = openrouter:models(),
    ?assertEqual(<<"test/model-1">>, maps:get(<<"id">>, Model)),
    ?assertEqual(4096, maps:get(<<"context_length">>, Model)).

models_auth_error(_Config) ->
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 401, <<"message">> => <<"Invalid key">>}
    }),
    mock_openrouter:set_response(models, {401, ErrorBody}),
    {error, Error} = openrouter:models(),
    ?assertEqual(auth_error, Error#api_error.type).

models_server_error(_Config) ->
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 500, <<"message">> => <<"Server error">>}
    }),
    mock_openrouter:set_response(models, {500, ErrorBody}),
    {error, Error} = openrouter:models(),
    ?assertEqual(server_error, Error#api_error.type).

%% Key info tests

key_info_success(_Config) ->
    {ok, KeyBody} = openrouter_json:encode(#{
        <<"data">> => #{
            <<"label">> => <<"My Key">>,
            <<"limit">> => 100.0,
            <<"usage">> => 42.5,
            <<"is_free_tier">> => false
        }
    }),
    mock_openrouter:set_response(auth_key, {200, KeyBody}),
    {ok, KeyData} = openrouter:key_info(),
    ?assertEqual(<<"My Key">>, maps:get(<<"label">>, KeyData)).

key_info_returns_data(_Config) ->
    {ok, KeyBody} = openrouter_json:encode(#{
        <<"data">> => #{
            <<"label">> => <<"Test">>,
            <<"limit">> => 50.0,
            <<"usage">> => 10.0,
            <<"is_free_tier">> => true,
            <<"rate_limit">> => #{<<"requests">> => 10, <<"interval">> => <<"10s">>}
        }
    }),
    mock_openrouter:set_response(auth_key, {200, KeyBody}),
    {ok, KeyData} = openrouter:key_info(),
    ?assertEqual(50.0, maps:get(<<"limit">>, KeyData)),
    ?assertEqual(true, maps:get(<<"is_free_tier">>, KeyData)),
    RateLimit = maps:get(<<"rate_limit">>, KeyData),
    ?assertEqual(10, maps:get(<<"requests">>, RateLimit)).

key_info_auth_error(_Config) ->
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 401, <<"message">> => <<"Invalid key">>}
    }),
    mock_openrouter:set_response(auth_key, {401, ErrorBody}),
    {error, Error} = openrouter:key_info(),
    ?assertEqual(auth_error, Error#api_error.type).
