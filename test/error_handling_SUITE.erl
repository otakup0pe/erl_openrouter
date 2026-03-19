-module(error_handling_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    auth_error_401/1,
    insufficient_credits_402/1,
    forbidden_403/1,
    rate_limited_429/1,
    server_error_500/1,
    error_with_message/1,
    error_with_metadata/1
]).

all() -> [{group, error_handling}].

groups() ->
    [{error_handling, [sequence], [
        auth_error_401,
        insufficient_credits_402,
        forbidden_403,
        rate_limited_429,
        server_error_500,
        error_with_message,
        error_with_metadata
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
        auth_callback => fun() -> {ok, <<"sk-test">>} end,
        max_retries => 0
    }),
    unlink(Pid),
    [{client_pid, Pid}, {base_url, BaseUrl} | Config].

end_per_testcase(_TC, Config) ->
    Pid = proplists:get_value(client_pid, Config),
    gen_server:stop(Pid),
    mock_openrouter:stop().

%% Helpers

set_error_response(StatusCode, ErrorCode, Message) ->
    {ok, Body} = openrouter_json:encode(#{
        <<"error">> => #{
            <<"code">> => ErrorCode,
            <<"message">> => Message
        }
    }),
    mock_openrouter:set_response({StatusCode, Body}).

chat_request() ->
    openrouter:chat([#{<<"role">> => <<"user">>, <<"content">> => <<"test">>}]).

%% Tests

auth_error_401(_Config) ->
    set_error_response(401, 401, <<"Invalid API key">>),
    {error, Error} = chat_request(),
    ?assertEqual(auth_error, Error#api_error.type),
    ?assertEqual(401, Error#api_error.code).

insufficient_credits_402(_Config) ->
    set_error_response(402, 402, <<"Insufficient credits">>),
    {error, Error} = chat_request(),
    ?assertEqual(insufficient_credits, Error#api_error.type).

forbidden_403(_Config) ->
    set_error_response(403, 403, <<"Forbidden">>),
    {error, Error} = chat_request(),
    ?assertEqual(forbidden, Error#api_error.type).

rate_limited_429(_Config) ->
    set_error_response(429, 429, <<"Rate limit exceeded">>),
    {error, Error} = chat_request(),
    ?assertEqual(rate_limited, Error#api_error.type),
    ?assertEqual(<<"Rate limit exceeded">>, Error#api_error.message).

server_error_500(_Config) ->
    set_error_response(500, 500, <<"Internal server error">>),
    {error, Error} = chat_request(),
    ?assertEqual(server_error, Error#api_error.type).

error_with_message(_Config) ->
    set_error_response(429, 429, <<"Please slow down">>),
    {error, Error} = chat_request(),
    ?assertEqual(<<"Please slow down">>, Error#api_error.message).

error_with_metadata(_Config) ->
    {ok, Body} = openrouter_json:encode(#{
        <<"error">> => #{
            <<"code">> => 429,
            <<"message">> => <<"Rate limited">>,
            <<"metadata">> => #{<<"retry_after">> => 60, <<"limit">> => 100}
        }
    }),
    mock_openrouter:set_response({429, Body}),
    {error, Error} = chat_request(),
    ?assertEqual(rate_limited, Error#api_error.type),
    Metadata = Error#api_error.metadata,
    ?assertEqual(60, maps:get(<<"retry_after">>, Metadata)),
    ?assertEqual(100, maps:get(<<"limit">>, Metadata)).
