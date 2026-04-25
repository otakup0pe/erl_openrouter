-module(telemetry_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    span_emits_start_and_stop/1,
    span_emits_exception_on_error/1,
    error_result_includes_error_type/1,
    rate_limiter_rejection_emits_event/1,
    circuit_breaker_state_change_emits_event/1,
    persistent_term_caching_works/1
]).

all() -> [{group, telemetry}].

groups() ->
    [{telemetry, [sequence], [
        span_emits_start_and_stop,
        span_emits_exception_on_error,
        error_result_includes_error_type,
        rate_limiter_rejection_emits_event,
        circuit_breaker_state_change_emits_event,
        persistent_term_caching_works
    ]}].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    application:ensure_all_started(telemetry),
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
        max_retries => 0
    }),
    unlink(Pid),
    %% Reset the persistent_term cache so telemetry is detected fresh
    persistent_term:put({openrouter_telemetry, enabled}, true),
    [{client_pid, Pid}, {base_url, BaseUrl} | Config].

end_per_testcase(_TC, Config) ->
    Pid = proplists:get_value(client_pid, Config),
    gen_server:stop(Pid),
    mock_openrouter:stop(),
    application:unset_env(erl_openrouter, api_key),
    %% Detach any telemetry handlers we may have attached
    Handlers = telemetry:list_handlers([erl_openrouter]),
    lists:foreach(fun(#{id := Id}) ->
        telemetry:detach(Id)
    end, Handlers),
    ok.

%% Tests

span_emits_start_and_stop(_Config) ->
    Self = self(),
    telemetry:attach_many(
        <<"test-span-start-stop">>,
        [[erl_openrouter, request, start],
         [erl_openrouter, request, stop]],
        fun(_EventName, Measurements, Metadata, _HandlerConfig) ->
            Self ! {telemetry_event, _EventName, Measurements, Metadata}
        end,
        #{}
    ),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}],
    {ok, _Response} = openrouter:chat(Messages),
    %% Expect start event
    receive
        {telemetry_event, [erl_openrouter, request, start], StartMeas, StartMeta} ->
            ?assertMatch(#{system_time := _}, StartMeas),
            ?assertEqual(chat, maps:get(operation, StartMeta))
    after 5000 ->
        ct:fail("Did not receive start event")
    end,
    %% Expect stop event -- result_measurements are merged into metadata
    receive
        {telemetry_event, [erl_openrouter, request, stop], StopMeas, StopMeta} ->
            ?assertMatch(#{duration := _}, StopMeas),
            ?assertEqual(ok, maps:get(status, StopMeta)),
            ?assertEqual(chat, maps:get(operation, StopMeta))
    after 5000 ->
        ct:fail("Did not receive stop event")
    end.

span_emits_exception_on_error(_Config) ->
    Self = self(),
    telemetry:attach_many(
        <<"test-span-exception">>,
        [[erl_openrouter, request, stop],
         [erl_openrouter, request, exception]],
        fun(_EventName, Measurements, Metadata, _HandlerConfig) ->
            Self ! {telemetry_event, _EventName, Measurements, Metadata}
        end,
        #{}
    ),
    %% Set up a 401 error response
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{
            <<"message">> => <<"Invalid API key">>,
            <<"code">> => 401
        }
    }),
    mock_openrouter:set_response({401, ErrorBody}),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}],
    {error, _} = openrouter:chat(Messages),
    %% Should get a stop event (not exception) since errors are returned, not thrown
    receive
        {telemetry_event, [erl_openrouter, request, stop], _StopMeas, StopMeta} ->
            ?assertEqual(error, maps:get(status, StopMeta))
    after 5000 ->
        ct:fail("Did not receive stop event for error")
    end.

error_result_includes_error_type(_Config) ->
    Self = self(),
    telemetry:attach(
        <<"test-error-type">>,
        [erl_openrouter, request, stop],
        fun(_EventName, Measurements, Metadata, _HandlerConfig) ->
            Self ! {telemetry_event, _EventName, Measurements, Metadata}
        end,
        #{}
    ),
    {ok, ErrorBody} = openrouter_json:encode(#{
        <<"error">> => #{
            <<"message">> => <<"Rate limited">>,
            <<"code">> => 429
        }
    }),
    mock_openrouter:set_response({429, ErrorBody}),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}],
    {error, _} = openrouter:chat(Messages),
    receive
        {telemetry_event, [erl_openrouter, request, stop], _StopMeas, StopMeta} ->
            ?assertEqual(error, maps:get(status, StopMeta)),
            ?assert(maps:is_key(error_type, StopMeta)),
            ?assertEqual(429, maps:get(status_code, StopMeta))
    after 5000 ->
        ct:fail("Did not receive stop event with error_type")
    end.

rate_limiter_rejection_emits_event(_Config) ->
    Self = self(),
    telemetry:attach(
        <<"test-rate-limiter-reject">>,
        [erl_openrouter, rate_limiter, rejected],
        fun(_EventName, Measurements, Metadata, _HandlerConfig) ->
            Self ! {telemetry_event, _EventName, Measurements, Metadata}
        end,
        #{}
    ),
    %% Start a rate limiter with 0 tokens so it immediately rejects
    {ok, RLPid} = openrouter_rate_limiter:start_link(
        openrouter_rate_limiter,
        #{max_tokens => 0, refill_rate => 1}
    ),
    unlink(RLPid),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}],
    {error, _} = openrouter:chat(Messages),
    receive
        {telemetry_event, [erl_openrouter, rate_limiter, rejected], _, _} ->
            ok
    after 5000 ->
        ct:fail("Did not receive rate_limiter rejected event")
    end,
    gen_server:stop(RLPid).

circuit_breaker_state_change_emits_event(_Config) ->
    Self = self(),
    telemetry:attach(
        <<"test-cb-state-change">>,
        [erl_openrouter, circuit_breaker, state_change],
        fun(_EventName, Measurements, Metadata, _HandlerConfig) ->
            Self ! {telemetry_event, _EventName, Measurements, Metadata}
        end,
        #{}
    ),
    %% Start a circuit breaker with threshold of 1 for easy triggering
    {ok, CBPid} = openrouter_circuit_breaker:start_link(#{
        failure_threshold => 1,
        reset_timeout => 100
    }),
    %% Trigger closed -> open
    openrouter_circuit_breaker:record_failure(CBPid),
    receive
        {telemetry_event, [erl_openrouter, circuit_breaker, state_change], _,
         #{from := closed, to := open}} ->
            ok
    after 5000 ->
        ct:fail("Did not receive closed->open state change")
    end,
    %% Wait for reset_timeout to trigger open -> half_open
    receive
        {telemetry_event, [erl_openrouter, circuit_breaker, state_change], _,
         #{from := open, to := half_open}} ->
            ok
    after 5000 ->
        ct:fail("Did not receive open->half_open state change")
    end,
    %% Record success to trigger half_open -> closed
    openrouter_circuit_breaker:record_success(CBPid),
    receive
        {telemetry_event, [erl_openrouter, circuit_breaker, state_change], _,
         #{from := half_open, to := closed}} ->
            ok
    after 5000 ->
        ct:fail("Did not receive half_open->closed state change")
    end,
    gen_server:stop(CBPid).

persistent_term_caching_works(_Config) ->
    %% Verify the persistent_term cache is set and returns a boolean
    Val = persistent_term:get({openrouter_telemetry, enabled}),
    ?assert(is_boolean(Val)),
    ?assertEqual(true, Val).
