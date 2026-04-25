-module(embeddings_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    simple_embedding_request/1,
    embedding_with_model/1,
    embedding_with_all_opts/1,
    embedding_batch_input/1,
    embedding_request_headers_correct/1,
    embedding_request_body_structure/1,
    embedding_error_response/1,
    embedding_server_error_retries/1
]).

all() -> [{group, embeddings}].

groups() ->
    [{embeddings, [sequence], [
        simple_embedding_request,
        embedding_with_model,
        embedding_with_all_opts,
        embedding_batch_input,
        embedding_request_headers_correct,
        embedding_request_body_structure,
        embedding_error_response,
        embedding_server_error_retries
    ]}].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(embedding_server_error_retries, Config) ->
    ok = mock_openrouter:start(),
    Port = mock_openrouter:port(),
    BaseUrl = "http://localhost:" ++ integer_to_list(Port) ++ "/api/v1",
    application:set_env(erl_openrouter, embedding_model,
                        <<"openai/text-embedding-3-small">>),
    {ok, Pid} = openrouter_client:start_link(#{
        base_url => BaseUrl,
        auth_callback => fun() -> {ok, <<"sk-test-key">>} end,
        max_retries => 2,
        backoff_base => 50,
        backoff_max => 100
    }),
    unlink(Pid),
    [{client_pid, Pid}, {base_url, BaseUrl} | Config];
init_per_testcase(_TC, Config) ->
    ok = mock_openrouter:start(),
    Port = mock_openrouter:port(),
    BaseUrl = "http://localhost:" ++ integer_to_list(Port) ++ "/api/v1",
    application:set_env(erl_openrouter, embedding_model,
                        <<"openai/text-embedding-3-small">>),
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
    application:unset_env(erl_openrouter, embedding_model),
    mock_openrouter:stop().

%% Helpers

set_embedding_response(ResponseBody) ->
    mock_openrouter:set_response(embeddings, {200, ResponseBody}).

default_embedding_response() ->
    {ok, Body} = openrouter_json:encode(#{
        <<"object">> => <<"list">>,
        <<"model">> => <<"openai/text-embedding-3-small">>,
        <<"data">> => [#{
            <<"object">> => <<"embedding">>,
            <<"index">> => 0,
            <<"embedding">> => [0.1, -0.2, 0.3, 0.4, -0.5]
        }],
        <<"usage">> => #{
            <<"prompt_tokens">> => 4,
            <<"total_tokens">> => 4
        }
    }),
    Body.

%% Tests

simple_embedding_request(_Config) ->
    set_embedding_response(default_embedding_response()),
    {ok, Response} = openrouter:embeddings(<<"hello world">>),
    ?assertMatch(#embedding_response{}, Response),
    ?assertEqual(<<"openai/text-embedding-3-small">>, Response#embedding_response.model),
    ?assertEqual(1, length(Response#embedding_response.data)),
    [Item] = Response#embedding_response.data,
    ?assertEqual(0, maps:get(index, Item)),
    ?assertEqual([0.1, -0.2, 0.3, 0.4, -0.5], maps:get(embedding, Item)).

embedding_with_model(_Config) ->
    set_embedding_response(default_embedding_response()),
    {ok, _} = openrouter:embeddings(<<"test">>,
        #{model => <<"openai/text-embedding-3-small">>}),
    #{body := ReqBody} = mock_openrouter:last_request(),
    {ok, Decoded} = openrouter_json:decode(ReqBody),
    ?assertEqual(<<"openai/text-embedding-3-small">>, maps:get(<<"model">>, Decoded)).

embedding_with_all_opts(_Config) ->
    set_embedding_response(default_embedding_response()),
    {ok, _} = openrouter:embeddings(<<"test">>, #{
        model => <<"openai/text-embedding-3-large">>,
        dimensions => 3072,
        encoding_format => <<"float">>
    }),
    #{body := ReqBody} = mock_openrouter:last_request(),
    {ok, Decoded} = openrouter_json:decode(ReqBody),
    ?assertEqual(<<"openai/text-embedding-3-large">>, maps:get(<<"model">>, Decoded)),
    ?assertEqual(3072, maps:get(<<"dimensions">>, Decoded)),
    ?assertEqual(<<"float">>, maps:get(<<"encoding_format">>, Decoded)).

embedding_batch_input(_Config) ->
    {ok, BatchBody} = openrouter_json:encode(#{
        <<"model">> => <<"test-model">>,
        <<"data">> => [
            #{<<"index">> => 0, <<"embedding">> => [0.1, 0.2]},
            #{<<"index">> => 1, <<"embedding">> => [0.3, 0.4]},
            #{<<"index">> => 2, <<"embedding">> => [0.5, 0.6]}
        ],
        <<"usage">> => #{<<"prompt_tokens">> => 12, <<"total_tokens">> => 12}
    }),
    set_embedding_response(BatchBody),
    {ok, Response} = openrouter:embeddings([<<"first">>, <<"second">>, <<"third">>]),
    ?assertEqual(3, length(Response#embedding_response.data)),
    #{body := ReqBody} = mock_openrouter:last_request(),
    {ok, Decoded} = openrouter_json:decode(ReqBody),
    ?assertEqual([<<"first">>, <<"second">>, <<"third">>],
                 maps:get(<<"input">>, Decoded)).

embedding_request_headers_correct(_Config) ->
    set_embedding_response(default_embedding_response()),
    {ok, _} = openrouter:embeddings(<<"test">>),
    #{headers := Headers} = mock_openrouter:last_request(),
    ?assertEqual(<<"Bearer sk-test-key">>, maps:get(<<"authorization">>, Headers)).

embedding_request_body_structure(_Config) ->
    set_embedding_response(default_embedding_response()),
    {ok, _} = openrouter:embeddings(<<"test input">>),
    #{body := ReqBody} = mock_openrouter:last_request(),
    {ok, Decoded} = openrouter_json:decode(ReqBody),
    ?assertEqual(<<"test input">>, maps:get(<<"input">>, Decoded)).

embedding_error_response(_Config) ->
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 401, <<"message">> => <<"Invalid API key">>}
    }),
    mock_openrouter:set_response(embeddings, {401, ErrorBody}),
    {error, Error} = openrouter:embeddings(<<"test">>),
    ?assertEqual(auth_error, Error#api_error.type),
    ?assertEqual(401, Error#api_error.code).

embedding_server_error_retries(_Config) ->
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 500, <<"message">> => <<"Server error">>}
    }),
    mock_openrouter:set_response(embeddings, {500, ErrorBody}),
    {error, Error} = openrouter:embeddings(<<"test">>),
    ?assertEqual(server_error, Error#api_error.type),
    %% 1 initial + 2 retries = 3
    ?assertEqual(3, mock_openrouter:request_count()).
