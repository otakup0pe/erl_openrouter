-module(generation_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    fetch_generation_success/1,
    fetch_generation_auth_error/1
]).

all() -> [
    fetch_generation_success,
    fetch_generation_auth_error
].

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
    application:unset_env(erl_openrouter, api_key),
    application:unset_env(erl_openrouter, base_url).

%% Tests

fetch_generation_success(_Config) ->
    {ok, GenBody} = openrouter_json:encode(#{
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
    mock_openrouter:set_response(generation, {200, GenBody}),
    {ok, Data} = openrouter:generation(<<"gen-abc123">>),
    ?assertEqual(<<"gen-abc123">>, maps:get(<<"id">>, Data)),
    ?assertEqual(0.0012, maps:get(<<"total_cost">>, Data)),
    ?assertEqual(1234, maps:get(<<"latency">>, Data)),
    ?assertEqual(987, maps:get(<<"generation_time">>, Data)),
    ?assertEqual(<<"OpenAI">>, maps:get(<<"provider_name">>, Data)),
    ?assertEqual(50, maps:get(<<"tokens_prompt">>, Data)),
    ?assertEqual(25, maps:get(<<"tokens_completion">>, Data)).

fetch_generation_auth_error(_Config) ->
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 401, <<"message">> => <<"Invalid key">>}
    }),
    mock_openrouter:set_response(generation, {401, ErrorBody}),
    {error, Error} = openrouter:generation(<<"gen-abc123">>),
    ?assertEqual(auth_error, Error#api_error.type).
