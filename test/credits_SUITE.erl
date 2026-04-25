-module(credits_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    fetch_credits_success/1,
    fetch_credits_auth_error/1,
    credits_response_parsing/1,
    credits_missing_data_field/1,
    credits_invalid_json/1
]).

all() -> [{group, credits}].

groups() ->
    [{credits, [sequence], [
        fetch_credits_success,
        fetch_credits_auth_error,
        credits_response_parsing,
        credits_missing_data_field,
        credits_invalid_json
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
    application:unset_env(erl_openrouter, api_key),
    application:unset_env(erl_openrouter, base_url).

%% Tests

fetch_credits_success(_Config) ->
    {ok, CreditsBody} = openrouter_json:encode(#{
        <<"data">> => #{
            <<"total_credits">> => 100.0,
            <<"total_usage">> => 23.5
        }
    }),
    mock_openrouter:set_response(credits, {200, CreditsBody}),
    {ok, Credits} = openrouter:credits(),
    ?assertEqual(100.0, maps:get(<<"total_credits">>, Credits)),
    ?assertEqual(23.5, maps:get(<<"total_usage">>, Credits)).

fetch_credits_auth_error(_Config) ->
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 401, <<"message">> => <<"Invalid management key">>}
    }),
    mock_openrouter:set_response(credits, {401, ErrorBody}),
    {error, Error} = openrouter:credits(),
    ?assertEqual(auth_error, Error#api_error.type).

credits_response_parsing(_Config) ->
    {ok, CreditsBody} = openrouter_json:encode(#{
        <<"data">> => #{
            <<"total_credits">> => 500.0,
            <<"total_usage">> => 150.25,
            <<"limit">> => 1000.0,
            <<"is_free_tier">> => false
        }
    }),
    mock_openrouter:set_response(credits, {200, CreditsBody}),
    {ok, Credits} = openrouter:credits(),
    ?assertEqual(500.0, maps:get(<<"total_credits">>, Credits)),
    ?assertEqual(150.25, maps:get(<<"total_usage">>, Credits)),
    ?assertEqual(false, maps:get(<<"is_free_tier">>, Credits)).

credits_missing_data_field(_Config) ->
    {ok, Body} = openrouter_json:encode(#{
        <<"total_credits">> => 100.0
    }),
    mock_openrouter:set_response(credits, {200, Body}),
    ?assertMatch({error, {unexpected_response, _}},
                 openrouter:credits()).

credits_invalid_json(_Config) ->
    mock_openrouter:set_response(credits, {200, <<"not json">>}),
    ?assertMatch({error, {parse_error, #{raw_body := _}}},
                 openrouter:credits()).
