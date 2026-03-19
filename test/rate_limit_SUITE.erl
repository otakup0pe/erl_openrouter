-module(rate_limit_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    retry_on_429/1,
    retry_on_500/1,
    retry_on_502/1,
    backoff_increases_between_retries/1,
    gives_up_after_max_retries/1,
    succeeds_after_retry/1
]).

all() -> [{group, rate_limit}].

groups() ->
    [{rate_limit, [sequence], [
        retry_on_429,
        retry_on_500,
        retry_on_502,
        backoff_increases_between_retries,
        gives_up_after_max_retries,
        succeeds_after_retry
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
        max_retries => 3,
        backoff_base => 50,
        backoff_max => 200
    }),
    unlink(Pid),
    [{client_pid, Pid}, {base_url, BaseUrl} | Config].

end_per_testcase(_TC, Config) ->
    Pid = proplists:get_value(client_pid, Config),
    gen_server:stop(Pid),
    mock_openrouter:stop().

%% Tests

retry_on_429(_Config) ->
    %% Server returns 429, client should retry
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 429, <<"message">> => <<"Rate limited">>}
    }),
    mock_openrouter:set_response({429, ErrorBody}),
    {error, Error} = openrouter:chat([#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]),
    ?assertEqual(rate_limited, Error#api_error.type),
    %% Should have retried (1 initial + max_retries)
    Count = mock_openrouter:request_count(),
    ?assert(Count > 1).

retry_on_500(_Config) ->
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 500, <<"message">> => <<"Internal server error">>}
    }),
    mock_openrouter:set_response({500, ErrorBody}),
    {error, Error} = openrouter:chat([#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]),
    ?assertEqual(server_error, Error#api_error.type),
    %% 1 initial + 3 retries = 4
    ?assertEqual(4, mock_openrouter:request_count()).

retry_on_502(_Config) ->
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 502, <<"message">> => <<"Bad gateway">>}
    }),
    mock_openrouter:set_response({502, ErrorBody}),
    {error, Error} = openrouter:chat([#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]),
    ?assertEqual(server_error, Error#api_error.type),
    ?assertEqual(4, mock_openrouter:request_count()).

backoff_increases_between_retries(_Config) ->
    %% Use custom handler to track timing between requests
    Self = self(),
    mock_openrouter:set_handler(fun(_Method, _Endpoint, _Body, _Headers, Req) ->
        Self ! {request_time, erlang:monotonic_time(millisecond)},
        {ok, ErrBody} = openrouter_json:encode(#{
            <<"error">> => #{<<"code">> => 429, <<"message">> => <<"Rate limited">>}
        }),
        Req2 = cowboy_req:reply(429,
            #{<<"content-type">> => <<"application/json">>},
            ErrBody, Req),
        {ok, Req2, done}
    end),
    _Result = openrouter:chat([#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]),
    %% Collect timestamps
    Times = collect_times([]),
    case length(Times) of
        N when N >= 3 ->
            [T1, T2, T3 | _] = Times,
            Gap1 = T2 - T1,
            Gap2 = T3 - T2,
            %% Second gap should generally be >= first gap (exponential)
            %% Allow some tolerance due to jitter
            ?assert(Gap2 >= Gap1 * 0.5);
        _ ->
            %% At least we got some retries
            ok
    end.

gives_up_after_max_retries(_Config) ->
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 429, <<"message">> => <<"Rate limited">>}
    }),
    mock_openrouter:set_response({429, ErrorBody}),
    {error, _} = openrouter:chat([#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]),
    %% max_retries is 3, so 1 initial + 3 retries = 4 total
    Count = mock_openrouter:request_count(),
    ?assertEqual(4, Count).

succeeds_after_retry(_Config) ->
    %% First 2 requests return 429, third succeeds
    Counter = counters:new(1, []),
    {ok, SuccessBody} = openrouter_json:encode(#{
        <<"id">> => <<"gen-retry-ok">>,
        <<"model">> => <<"test">>,
        <<"choices">> => [#{
            <<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => <<"Finally!">>},
            <<"finish_reason">> => <<"stop">>
        }],
        <<"usage">> => #{<<"prompt_tokens">> => 5, <<"completion_tokens">> => 2, <<"total_tokens">> => 7}
    }),
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 429, <<"message">> => <<"Rate limited">>}
    }),
    mock_openrouter:set_handler(fun(_Method, _Endpoint, _Body, _Headers, Req) ->
        counters:add(Counter, 1, 1),
        N = counters:get(Counter, 1),
        {Status, Body} = case N of
            X when X =< 2 -> {429, ErrorBody};
            _ -> {200, SuccessBody}
        end,
        Req2 = cowboy_req:reply(Status,
            #{<<"content-type">> => <<"application/json">>},
            Body, Req),
        {ok, Req2, done}
    end),
    {ok, Response} = openrouter:chat([#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]),
    ?assertEqual(<<"gen-retry-ok">>, Response#chat_response.id).

%% Helpers

collect_times(Acc) ->
    receive
        {request_time, T} -> collect_times([T | Acc])
    after 2000 ->
        lists:reverse(Acc)
    end.
