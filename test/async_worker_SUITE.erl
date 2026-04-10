-module(async_worker_SUITE).

%% Validates the async worker model in openrouter_client. Prior to
%% this suite, openrouter_client ran all HTTP calls synchronously
%% inside its handle_call, which serialized all OpenRouter traffic
%% through a single gen_server. The current implementation spawns
%% monitored workers per request so concurrent calls actually run
%% in parallel.
%%

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    concurrent_chat_calls_run_in_parallel/1,
    error_response_propagates_and_client_survives/1,
    gen_server_stays_responsive_during_long_call/1,
    many_concurrent_calls_all_complete/1
]).

all() -> [{group, async_worker}].

groups() ->
    [{async_worker, [sequence], [
        concurrent_chat_calls_run_in_parallel,
        error_response_propagates_and_client_survives,
        gen_server_stays_responsive_during_long_call,
        many_concurrent_calls_all_complete
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
        auth_callback => fun() -> {ok, <<"sk-test-key">>} end,
        max_retries => 0  %% disable retry for deterministic timing
    }),
    unlink(Pid),
    [{client_pid, Pid}, {base_url, BaseUrl} | Config].

end_per_testcase(_TC, Config) ->
    Pid = proplists:get_value(client_pid, Config),
    gen_server:stop(Pid),
    mock_openrouter:stop(),
    application:unset_env(erl_openrouter, api_key).

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

concurrent_chat_calls_run_in_parallel(_Config) ->
    mock_openrouter:set_delay(500),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}],
    Self = self(),
    N = 3,
    T0 = erlang:monotonic_time(millisecond),
    lists:foreach(fun(I) ->
        spawn_link(fun() ->
            Result = openrouter:chat(Messages),
            Self ! {done, I, Result}
        end)
    end, lists:seq(1, N)),
    Results = collect_results(N, []),
    T1 = erlang:monotonic_time(millisecond),
    Elapsed = T1 - T0,
    ?assertEqual(N, length(Results)),
    [?assertMatch({ok, #chat_response{}}, R) || R <- Results],
    %% Elapsed time should be closer to the single-call delay than
    %% to N * delay. With 500ms mock delay:
    %%   serialized = ~1500ms
    %%   parallel   = ~500ms
    %% Assert below the midpoint (~1000ms) with headroom.
    ?assert(Elapsed < 1200,
            lists:flatten(io_lib:format(
              "Expected parallel execution (< 1200ms), got ~pms",
              [Elapsed]))).

error_response_propagates_and_client_survives(_Config) ->
    mock_openrouter:set_response(
      chat_completions,
      {500, <<"{\"error\": {\"code\": 500, \"message\": \"boom\"}}">>}),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}],
    Result = openrouter:chat(Messages),
    ?assertMatch({error, _}, Result),
    ?assert(is_process_alive(whereis(openrouter_client))),
    mock_openrouter:reset(),
    {ok, _} = openrouter:chat(Messages),
    ok.

gen_server_stays_responsive_during_long_call(_Config) ->
    mock_openrouter:set_delay(800),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Slow">>}],
    Self = self(),
    spawn_link(fun() ->
        Result = openrouter:chat(Messages),
        Self ! {slow_done, Result}
    end),
    timer:sleep(100),
    T0 = erlang:monotonic_time(millisecond),
    {ok, _} = openrouter:chat(Messages),
    T1 = erlang:monotonic_time(millisecond),
    Elapsed = T1 - T0,
    ?assert(Elapsed < 1100,
            lists:flatten(io_lib:format(
              "Second call should overlap with first (<1100ms), got ~pms",
              [Elapsed]))),
    receive
        {slow_done, {ok, _}} -> ok
    after 3000 -> ct:fail(slow_call_never_completed)
    end.

many_concurrent_calls_all_complete(_Config) ->
    mock_openrouter:set_delay(200),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hi">>}],
    Self = self(),
    N = 10,
    T0 = erlang:monotonic_time(millisecond),
    lists:foreach(fun(I) ->
        spawn_link(fun() ->
            Result = openrouter:chat(Messages),
            Self ! {done, I, Result}
        end)
    end, lists:seq(1, N)),
    Results = collect_results(N, []),
    T1 = erlang:monotonic_time(millisecond),
    Elapsed = T1 - T0,
    ?assertEqual(N, length(Results)),
    [?assertMatch({ok, #chat_response{}}, R) || R <- Results],
    ?assert(Elapsed < 1000,
            lists:flatten(io_lib:format(
              "Expected parallel execution of 10 calls (<1000ms), "
              "got ~pms",
              [Elapsed]))).

collect_results(0, Acc) ->
    Acc;
collect_results(N, Acc) ->
    receive
        {done, _I, Result} ->
            collect_results(N - 1, [Result | Acc])
    after 5000 ->
        ct:fail({timeout_waiting_for_results, N, length(Acc)})
    end.
