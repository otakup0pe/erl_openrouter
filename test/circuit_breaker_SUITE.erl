-module(circuit_breaker_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    starts_closed/1,
    opens_after_threshold/1,
    rejects_when_open/1,
    half_open_allows_probe/1,
    closes_on_success/1,
    reopens_on_half_open_failure/1,
    model_stored_in_state/1,
    model_undefined_by_default/1,
    per_model_sup_creates_isolated_breakers/1,
    per_model_isolation/1,
    per_model_fallback_to_global/1,
    per_model_stale_pid_recovery/1,
    telemetry_includes_model/1
]).

all() -> [{group, circuit_breaker}, {group, per_model}].

groups() ->
    [{circuit_breaker, [sequence], [
        starts_closed,
        opens_after_threshold,
        rejects_when_open,
        half_open_allows_probe,
        closes_on_success,
        reopens_on_half_open_failure
    ]},
     {per_model, [sequence], [
        model_stored_in_state,
        model_undefined_by_default,
        per_model_sup_creates_isolated_breakers,
        per_model_isolation,
        per_model_fallback_to_global,
        per_model_stale_pid_recovery,
        telemetry_includes_model
    ]}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TC, Config) when
      TC =:= per_model_sup_creates_isolated_breakers;
      TC =:= per_model_isolation;
      TC =:= per_model_fallback_to_global;
      TC =:= per_model_stale_pid_recovery ->
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 3, reset_timeout => 100}),
    {ok, SupPid} = openrouter_circuit_breaker_sup:start_link(),
    [{sup_pid, SupPid} | Config];
init_per_testcase(telemetry_includes_model, Config) ->
    {ok, _} = application:ensure_all_started(telemetry),
    %% Clear the cached enabled flag so openrouter_telemetry sees telemetry
    catch persistent_term:erase({openrouter_telemetry, enabled}),
    Self = self(),
    Ref = make_ref(),
    telemetry:attach(
        <<"cb_test_handler">>,
        [erl_openrouter, circuit_breaker, state_change],
        fun(_Event, _Meas, Meta, {Pid, Tag}) ->
            Pid ! {Tag, Meta}
        end,
        {Self, Ref}),
    {ok, Pid} = openrouter_circuit_breaker:start_link(#{
        failure_threshold => 2,
        reset_timeout => 100,
        model => <<"test/model-a">>
    }),
    [{cb_pid, Pid}, {tel_ref, Ref} | Config];
init_per_testcase(_TC, Config) ->
    {ok, Pid} = openrouter_circuit_breaker:start_link(#{
        failure_threshold => 3,
        reset_timeout => 100
    }),
    [{cb_pid, Pid} | Config].

end_per_testcase(TC, Config) when
      TC =:= per_model_sup_creates_isolated_breakers;
      TC =:= per_model_isolation;
      TC =:= per_model_fallback_to_global;
      TC =:= per_model_stale_pid_recovery ->
    SupPid = proplists:get_value(sup_pid, Config),
    case is_process_alive(SupPid) of
        true ->
            MonRef = monitor(process, SupPid),
            unlink(SupPid),
            exit(SupPid, shutdown),
            receive {'DOWN', MonRef, process, _, _} -> ok
            after 2000 -> ok end;
        false -> ok
    end,
    catch ets:delete(openrouter_circuit_breaker_registry),
    ok;
end_per_testcase(telemetry_includes_model, Config) ->
    catch telemetry:detach(<<"cb_test_handler">>),
    Pid = proplists:get_value(cb_pid, Config),
    catch gen_server:stop(Pid),
    ok;
end_per_testcase(_TC, Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    catch gen_server:stop(Pid),
    ok.

%% Tests

starts_closed(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    ?assertEqual(closed, openrouter_circuit_breaker:state(Pid)).

opens_after_threshold(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    ?assertEqual(closed, openrouter_circuit_breaker:state(Pid)),
    openrouter_circuit_breaker:record_failure(Pid),
    ?assertEqual(open, openrouter_circuit_breaker:state(Pid)).

rejects_when_open(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    %% Trip the breaker
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    ?assertEqual(open, openrouter_circuit_breaker:state(Pid)),
    ?assertEqual({error, circuit_open}, openrouter_circuit_breaker:allow(Pid)).

half_open_allows_probe(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    %% Trip the breaker
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    ?assertEqual(open, openrouter_circuit_breaker:state(Pid)),
    %% Wait for reset timeout
    timer:sleep(150),
    ?assertEqual(half_open, openrouter_circuit_breaker:state(Pid)),
    ?assertEqual(ok, openrouter_circuit_breaker:allow(Pid)).

closes_on_success(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    %% Trip, wait for half_open, then record success
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    timer:sleep(150),
    ?assertEqual(half_open, openrouter_circuit_breaker:state(Pid)),
    openrouter_circuit_breaker:record_success(Pid),
    ?assertEqual(closed, openrouter_circuit_breaker:state(Pid)).

reopens_on_half_open_failure(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    %% Trip, wait for half_open, then fail again
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    timer:sleep(150),
    ?assertEqual(half_open, openrouter_circuit_breaker:state(Pid)),
    openrouter_circuit_breaker:record_failure(Pid),
    ?assertEqual(open, openrouter_circuit_breaker:state(Pid)).

%% --- Per-model tests ---

model_stored_in_state(_Config) ->
    {ok, Pid} = openrouter_circuit_breaker:start_link(#{
        model => <<"google/gemma-4-26b">>
    }),
    ?assertEqual(<<"google/gemma-4-26b">>, openrouter_circuit_breaker:model(Pid)),
    gen_server:stop(Pid).

model_undefined_by_default(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    ?assertEqual(undefined, openrouter_circuit_breaker:model(Pid)).

per_model_sup_creates_isolated_breakers(_Config) ->
    PidA = openrouter_circuit_breaker_sup:ensure(<<"model-a">>),
    PidB = openrouter_circuit_breaker_sup:ensure(<<"model-b">>),
    ?assert(is_pid(PidA)),
    ?assert(is_pid(PidB)),
    ?assertNotEqual(PidA, PidB),
    %% Same model returns same pid
    PidA2 = openrouter_circuit_breaker_sup:ensure(<<"model-a">>),
    ?assertEqual(PidA, PidA2).

per_model_isolation(_Config) ->
    PidA = openrouter_circuit_breaker_sup:ensure(<<"model-a">>),
    PidB = openrouter_circuit_breaker_sup:ensure(<<"model-b">>),
    %% Trip model-a
    openrouter_circuit_breaker:record_failure(PidA),
    openrouter_circuit_breaker:record_failure(PidA),
    openrouter_circuit_breaker:record_failure(PidA),
    ?assertEqual(open, openrouter_circuit_breaker:state(PidA)),
    %% Model-b stays closed
    ?assertEqual(closed, openrouter_circuit_breaker:state(PidB)),
    ?assertEqual(ok, openrouter_circuit_breaker:allow(PidB)).

per_model_fallback_to_global(_Config) ->
    %% undefined model should fall back to global (or undefined if not registered)
    Result = openrouter_circuit_breaker_sup:ensure(undefined),
    %% Global breaker not registered in this test, so undefined
    ?assertEqual(undefined, Result).

per_model_stale_pid_recovery(_Config) ->
    PidA = openrouter_circuit_breaker_sup:ensure(<<"model-stale">>),
    ?assert(is_pid(PidA)),
    gen_server:stop(PidA),
    timer:sleep(10),
    %% Stale pid should be detected and a new breaker started
    PidA2 = openrouter_circuit_breaker_sup:ensure(<<"model-stale">>),
    ?assert(is_pid(PidA2)),
    ?assertNotEqual(PidA, PidA2),
    ?assertEqual(closed, openrouter_circuit_breaker:state(PidA2)).

telemetry_includes_model(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    Ref = proplists:get_value(tel_ref, Config),
    %% Trip the breaker (threshold=2)
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    %% Should get closed->open event with model
    receive
        {Ref, #{from := closed, to := open, model := Model}} ->
            ?assertEqual(<<"test/model-a">>, Model)
    after 1000 ->
        ct:fail("no telemetry event received for closed->open")
    end,
    %% Wait for half_open
    timer:sleep(150),
    receive
        {Ref, #{from := open, to := half_open, model := Model2}} ->
            ?assertEqual(<<"test/model-a">>, Model2)
    after 1000 ->
        ct:fail("no telemetry event received for open->half_open")
    end.
