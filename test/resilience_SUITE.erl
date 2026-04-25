-module(resilience_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

%% Tests that the rate limiter, circuit breaker, in-flight cap, and
%% auth fail-fast are wired into the client's request path.

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    rate_limiter_rejects_when_exhausted/1,
    circuit_breaker_rejects_when_open/1,
    circuit_breaker_opens_after_server_errors/1,
    circuit_breaker_closes_after_success/1,
    client_errors_do_not_trip_breaker/1,
    circuit_breaker_checked_on_retry/1,
    in_flight_cap_rejects_excess/1,
    auth_fail_fast_no_http/1,
    stream_opt_rejected/1,
    all_errors_are_api_error/1,
    retry_after_header_respected/1
]).

all() -> [{group, resilience}].

groups() ->
    [{resilience, [sequence], [
        rate_limiter_rejects_when_exhausted,
        circuit_breaker_rejects_when_open,
        circuit_breaker_opens_after_server_errors,
        circuit_breaker_closes_after_success,
        client_errors_do_not_trip_breaker,
        circuit_breaker_checked_on_retry,
        in_flight_cap_rejects_excess,
        auth_fail_fast_no_http,
        stream_opt_rejected,
        all_errors_are_api_error,
        retry_after_header_respected
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
    {ok, RLPid} = openrouter_rate_limiter:start_link(
        openrouter_rate_limiter,
        #{max_tokens => 3, refill_interval => 60000}),
    {ok, CBPid} = openrouter_circuit_breaker:start_link(
        openrouter_circuit_breaker,
        #{failure_threshold => 3, reset_timeout => 100}),
    {ok, ClientPid} = openrouter_client:start_link(#{
        base_url => BaseUrl,
        auth_callback => fun() -> {ok, <<"sk-test">>} end,
        max_retries => 0,
        backoff_base => 10,
        backoff_max => 50,
        max_in_flight => 3
    }),
    unlink(ClientPid),
    unlink(RLPid),
    unlink(CBPid),
    [{client_pid, ClientPid}, {rl_pid, RLPid}, {cb_pid, CBPid},
     {base_url, BaseUrl} | Config].

end_per_testcase(_TC, Config) ->
    Pid = proplists:get_value(client_pid, Config),
    RLPid = proplists:get_value(rl_pid, Config),
    CBPid = proplists:get_value(cb_pid, Config),
    catch gen_server:stop(Pid),
    catch gen_server:stop(RLPid),
    catch gen_server:stop(CBPid),
    mock_openrouter:stop().

%% -- Tests ---------------------------------------------------------------

msg() -> [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}].

rate_limiter_rejects_when_exhausted(_Config) ->
    {ok, _} = openrouter:chat(msg()),
    {ok, _} = openrouter:chat(msg()),
    {ok, _} = openrouter:chat(msg()),
    CountBefore = mock_openrouter:request_count(),
    {error, Err} = openrouter:chat(msg()),
    ?assertEqual(rate_limited, Err#api_error.type),
    ?assertEqual(local, maps:get(source, Err#api_error.metadata)),
    CountAfter = mock_openrouter:request_count(),
    ?assertEqual(CountBefore, CountAfter).

circuit_breaker_rejects_when_open(_Config) ->
    openrouter_circuit_breaker:record_failure(openrouter_circuit_breaker),
    openrouter_circuit_breaker:record_failure(openrouter_circuit_breaker),
    openrouter_circuit_breaker:record_failure(openrouter_circuit_breaker),
    CountBefore = mock_openrouter:request_count(),
    {error, Err} = openrouter:chat(msg()),
    ?assertEqual(circuit_open, Err#api_error.type),
    ?assertEqual(local, maps:get(source, Err#api_error.metadata)),
    CountAfter = mock_openrouter:request_count(),
    ?assertEqual(CountBefore, CountAfter).

circuit_breaker_opens_after_server_errors(_Config) ->
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 500, <<"message">> => <<"boom">>}
    }),
    mock_openrouter:set_response({500, ErrorBody}),
    {error, _} = openrouter:chat(msg()),
    {error, _} = openrouter:chat(msg()),
    {error, _} = openrouter:chat(msg()),
    ?assertEqual(open, openrouter_circuit_breaker:state(openrouter_circuit_breaker)).

circuit_breaker_closes_after_success(_Config) ->
    openrouter_circuit_breaker:record_failure(openrouter_circuit_breaker),
    openrouter_circuit_breaker:record_failure(openrouter_circuit_breaker),
    openrouter_circuit_breaker:record_failure(openrouter_circuit_breaker),
    timer:sleep(150),
    ?assertEqual(half_open, openrouter_circuit_breaker:state(openrouter_circuit_breaker)),
    {ok, _} = openrouter:chat(msg()),
    ?assertEqual(closed, openrouter_circuit_breaker:state(openrouter_circuit_breaker)).

client_errors_do_not_trip_breaker(_Config) ->
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 401, <<"message">> => <<"bad key">>}
    }),
    mock_openrouter:set_response({401, ErrorBody}),
    {error, _} = openrouter:chat(msg()),
    {error, _} = openrouter:chat(msg()),
    {error, _} = openrouter:chat(msg()),
    ?assertEqual(closed, openrouter_circuit_breaker:state(openrouter_circuit_breaker)).

circuit_breaker_checked_on_retry(Config) ->
    gen_server:stop(proplists:get_value(client_pid, Config)),
    BaseUrl = proplists:get_value(base_url, Config),
    {ok, NewPid} = openrouter_client:start_link(#{
        base_url => BaseUrl,
        auth_callback => fun() -> {ok, <<"sk-test">>} end,
        max_retries => 5,
        backoff_base => 10,
        backoff_max => 20
    }),
    unlink(NewPid),
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 500, <<"message">> => <<"boom">>}
    }),
    mock_openrouter:set_response({500, ErrorBody}),
    {error, _} = openrouter:chat(msg()),
    ?assertEqual(open, openrouter_circuit_breaker:state(openrouter_circuit_breaker)),
    Count = mock_openrouter:request_count(),
    ?assert(Count =< 4),
    gen_server:stop(NewPid).

in_flight_cap_rejects_excess(_Config) ->
    %% max_in_flight is 3. Use slow mock to fill all slots.
    mock_openrouter:set_delay(500),
    Pids = [spawn_link(fun() ->
        Result = openrouter:chat(msg()),
        receive {get_result, From} -> From ! {result, Result} end
    end) || _ <- lists:seq(1, 3)],
    %% Give workers time to start their HTTP calls
    timer:sleep(50),
    %% 4th call should be rejected immediately
    {error, Err} = openrouter:chat(msg()),
    ?assertEqual(overloaded, Err#api_error.type),
    ?assertEqual(local, maps:get(source, Err#api_error.metadata)),
    %% Clean up
    lists:foreach(fun(P) ->
        P ! {get_result, self()},
        receive {result, _} -> ok after 2000 -> ok end
    end, Pids).

auth_fail_fast_no_http(Config) ->
    %% Start a client with explicitly no auth. Must override any
    %% OPENROUTER_API_KEY from the environment (e.g. direnv).
    gen_server:stop(proplists:get_value(client_pid, Config)),
    OldKey = os:getenv("OPENROUTER_API_KEY"),
    os:unsetenv("OPENROUTER_API_KEY"),
    OldAppKey = application:get_env(erl_openrouter, api_key),
    application:unset_env(erl_openrouter, api_key),
    BaseUrl = proplists:get_value(base_url, Config),
    {ok, NoAuthPid} = openrouter_client:start_link(#{
        base_url => BaseUrl
    }),
    unlink(NoAuthPid),
    CountBefore = mock_openrouter:request_count(),
    {error, Err} = openrouter:chat(msg()),
    ?assertEqual(auth_error, Err#api_error.type),
    ?assertEqual(local, maps:get(source, Err#api_error.metadata)),
    CountAfter = mock_openrouter:request_count(),
    ?assertEqual(CountBefore, CountAfter),
    gen_server:stop(NoAuthPid),
    %% Restore env
    case OldKey of
        false -> ok;
        K -> os:putenv("OPENROUTER_API_KEY", K)
    end,
    case OldAppKey of
        undefined -> ok;
        {ok, AK} -> application:set_env(erl_openrouter, api_key, AK)
    end.

stream_opt_rejected(_Config) ->
    {error, {stream_not_supported, _}} = openrouter:chat(
        msg(), #{stream => true}).

all_errors_are_api_error(_Config) ->
    %% Server error returns #api_error with source => remote
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 500, <<"message">> => <<"boom">>}
    }),
    mock_openrouter:set_response({500, ErrorBody}),
    {error, ServerErr} = openrouter:chat(msg()),
    ?assert(is_record(ServerErr, api_error)),
    ?assertEqual(remote, maps:get(source, ServerErr#api_error.metadata)).

retry_after_header_respected(Config) ->
    %% Reconfigure client with retries
    gen_server:stop(proplists:get_value(client_pid, Config)),
    BaseUrl = proplists:get_value(base_url, Config),
    {ok, NewPid} = openrouter_client:start_link(#{
        base_url => BaseUrl,
        auth_callback => fun() -> {ok, <<"sk-test">>} end,
        max_retries => 1,
        backoff_base => 10,
        backoff_max => 20
    }),
    unlink(NewPid),
    %% Mock returns 429 with Retry-After: 2 (seconds)
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{<<"code">> => 429, <<"message">> => <<"slow down">>}
    }),
    mock_openrouter:set_response({429, #{<<"retry-after">> => <<"2">>}, ErrorBody}),
    T0 = erlang:monotonic_time(millisecond),
    {error, _} = openrouter:chat(msg()),
    T1 = erlang:monotonic_time(millisecond),
    Elapsed = T1 - T0,
    %% Should have waited at least 2000ms (Retry-After) not just 10-20ms (backoff)
    ?assert(Elapsed >= 1800),
    gen_server:stop(NewPid).
