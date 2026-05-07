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
    op_stored_in_state/1,
    op_undefined_by_default/1,
    per_model_sup_creates_isolated_breakers/1,
    per_model_isolation/1,
    per_model_fallback_to_global/1,
    per_model_stale_pid_recovery/1,
    per_model_op_keys_are_distinct/1,
    per_op_opts_override_per_model/1,
    per_model_op_opts_override_per_op/1,
    telemetry_includes_model/1,
    telemetry_includes_op/1,
    %% Broken-world ratio scenarios
    ratio_trips_on_bursty_failures_with_interleaved_successes/1,
    legacy_consecutive_does_not_trip_with_interleaved_successes/1,
    ratio_min_attempts_gates_trip/1,
    ratio_window_age_expiry_recovers/1,
    ratio_burst_then_quiet_does_not_re_trip/1,
    ratio_half_open_reopen_keeps_window_clean/1
]).

all() ->
    [{group, circuit_breaker},
     {group, per_model},
     {group, per_op},
     {group, broken_world}].

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
     ]},
     {per_op, [sequence], [
        op_stored_in_state,
        op_undefined_by_default,
        per_model_op_keys_are_distinct,
        per_op_opts_override_per_model,
        per_model_op_opts_override_per_op,
        telemetry_includes_op
     ]},
     {broken_world, [sequence], [
        ratio_trips_on_bursty_failures_with_interleaved_successes,
        legacy_consecutive_does_not_trip_with_interleaved_successes,
        ratio_min_attempts_gates_trip,
        ratio_window_age_expiry_recovers,
        ratio_burst_then_quiet_does_not_re_trip,
        ratio_half_open_reopen_keeps_window_clean
     ]}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TC, Config) when
      TC =:= per_model_sup_creates_isolated_breakers;
      TC =:= per_model_isolation;
      TC =:= per_model_fallback_to_global;
      TC =:= per_model_stale_pid_recovery;
      TC =:= per_model_op_keys_are_distinct;
      TC =:= per_op_opts_override_per_model;
      TC =:= per_model_op_opts_override_per_op ->
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 3, reset_timeout => 100}),
    {ok, SupPid} = openrouter_circuit_breaker_sup:start_link(),
    [{sup_pid, SupPid} | Config];
init_per_testcase(TC, Config) when
      TC =:= telemetry_includes_model;
      TC =:= telemetry_includes_op ->
    {ok, _} = application:ensure_all_started(telemetry),
    catch persistent_term:erase({openrouter_telemetry, enabled}),
    Self = self(),
    Ref = make_ref(),
    HandlerId = list_to_binary("cb_test_" ++ atom_to_list(TC)),
    telemetry:attach(
        HandlerId,
        [erl_openrouter, circuit_breaker, state_change],
        fun(_Event, _Meas, Meta, {Pid, Tag}) ->
            Pid ! {Tag, Meta}
        end,
        {Self, Ref}),
    Opts = case TC of
        telemetry_includes_model ->
            #{failure_threshold => 2, reset_timeout => 100,
              model => <<"test/model-a">>};
        telemetry_includes_op ->
            #{failure_threshold => 2, reset_timeout => 100,
              model => <<"test/model-a">>, op => propose_merge}
    end,
    {ok, Pid} = openrouter_circuit_breaker:start_link(Opts),
    [{cb_pid, Pid}, {tel_ref, Ref}, {tel_handler_id, HandlerId} | Config];
init_per_testcase(TC, Config) when
      TC =:= ratio_trips_on_bursty_failures_with_interleaved_successes;
      TC =:= ratio_min_attempts_gates_trip;
      TC =:= ratio_window_age_expiry_recovers;
      TC =:= ratio_burst_then_quiet_does_not_re_trip;
      TC =:= ratio_half_open_reopen_keeps_window_clean ->
    Opts = ratio_opts_for(TC),
    {ok, Pid} = openrouter_circuit_breaker:start_link(Opts),
    [{cb_pid, Pid} | Config];
init_per_testcase(legacy_consecutive_does_not_trip_with_interleaved_successes,
                  Config) ->
    {ok, Pid} = openrouter_circuit_breaker:start_link(
        #{failure_threshold => 5, reset_timeout => 60000}),
    [{cb_pid, Pid} | Config];
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
      TC =:= per_model_stale_pid_recovery;
      TC =:= per_model_op_keys_are_distinct;
      TC =:= per_op_opts_override_per_model;
      TC =:= per_model_op_opts_override_per_op ->
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
    application:unset_env(erl_openrouter, per_model_circuit_breaker_opts),
    application:unset_env(erl_openrouter, per_op_circuit_breaker_opts),
    ok;
end_per_testcase(TC, Config) when
      TC =:= telemetry_includes_model;
      TC =:= telemetry_includes_op ->
    HandlerId = proplists:get_value(tel_handler_id, Config),
    catch telemetry:detach(HandlerId),
    Pid = proplists:get_value(cb_pid, Config),
    catch gen_server:stop(Pid),
    ok;
end_per_testcase(_TC, Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    catch gen_server:stop(Pid),
    ok.

%%====================================================================
%% Existing core tests
%%====================================================================

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
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    ?assertEqual(open, openrouter_circuit_breaker:state(Pid)),
    ?assertEqual({error, circuit_open}, openrouter_circuit_breaker:allow(Pid)).

half_open_allows_probe(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    ?assertEqual(open, openrouter_circuit_breaker:state(Pid)),
    timer:sleep(150),
    ?assertEqual(half_open, openrouter_circuit_breaker:state(Pid)),
    ?assertEqual(ok, openrouter_circuit_breaker:allow(Pid)).

closes_on_success(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    timer:sleep(150),
    ?assertEqual(half_open, openrouter_circuit_breaker:state(Pid)),
    openrouter_circuit_breaker:record_success(Pid),
    ?assertEqual(closed, openrouter_circuit_breaker:state(Pid)).

reopens_on_half_open_failure(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    timer:sleep(150),
    ?assertEqual(half_open, openrouter_circuit_breaker:state(Pid)),
    openrouter_circuit_breaker:record_failure(Pid),
    ?assertEqual(open, openrouter_circuit_breaker:state(Pid)).

%%====================================================================
%% Per-model
%%====================================================================

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
    PidA2 = openrouter_circuit_breaker_sup:ensure(<<"model-a">>),
    ?assertEqual(PidA, PidA2).

per_model_isolation(_Config) ->
    PidA = openrouter_circuit_breaker_sup:ensure(<<"model-a">>),
    PidB = openrouter_circuit_breaker_sup:ensure(<<"model-b">>),
    openrouter_circuit_breaker:record_failure(PidA),
    openrouter_circuit_breaker:record_failure(PidA),
    openrouter_circuit_breaker:record_failure(PidA),
    ?assertEqual(open, openrouter_circuit_breaker:state(PidA)),
    ?assertEqual(closed, openrouter_circuit_breaker:state(PidB)),
    ?assertEqual(ok, openrouter_circuit_breaker:allow(PidB)).

per_model_fallback_to_global(_Config) ->
    Result = openrouter_circuit_breaker_sup:ensure(undefined),
    ?assertEqual(undefined, Result).

per_model_stale_pid_recovery(_Config) ->
    PidA = openrouter_circuit_breaker_sup:ensure(<<"model-stale">>),
    ?assert(is_pid(PidA)),
    gen_server:stop(PidA),
    timer:sleep(10),
    PidA2 = openrouter_circuit_breaker_sup:ensure(<<"model-stale">>),
    ?assert(is_pid(PidA2)),
    ?assertNotEqual(PidA, PidA2),
    ?assertEqual(closed, openrouter_circuit_breaker:state(PidA2)).

telemetry_includes_model(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    Ref = proplists:get_value(tel_ref, Config),
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    receive
        {Ref, #{from := closed, to := open, model := Model}} ->
            ?assertEqual(<<"test/model-a">>, Model)
    after 1000 ->
        ct:fail("no telemetry event received for closed->open")
    end,
    timer:sleep(150),
    receive
        {Ref, #{from := open, to := half_open, model := Model2}} ->
            ?assertEqual(<<"test/model-a">>, Model2)
    after 1000 ->
        ct:fail("no telemetry event received for open->half_open")
    end.

%%====================================================================
%% Per-(Model, Op)
%%====================================================================

op_stored_in_state(_Config) ->
    {ok, Pid} = openrouter_circuit_breaker:start_link(#{
        model => <<"sonnet-4-6">>, op => propose_merge
    }),
    ?assertEqual(propose_merge, openrouter_circuit_breaker:op(Pid)),
    gen_server:stop(Pid).

op_undefined_by_default(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    ?assertEqual(undefined, openrouter_circuit_breaker:op(Pid)).

per_model_op_keys_are_distinct(_Config) ->
    %% (sonnet-4-6, propose_merge) and (sonnet-4-6, classify_path)
    %% should be distinct breakers; same model alone collapses to a
    %% single breaker.
    Pid1 = openrouter_circuit_breaker_sup:ensure(<<"sonnet-4-6">>, propose_merge),
    Pid2 = openrouter_circuit_breaker_sup:ensure(<<"sonnet-4-6">>, classify_path),
    Pid3 = openrouter_circuit_breaker_sup:ensure(<<"haiku-3">>, propose_merge),
    ?assertNotEqual(Pid1, Pid2),
    ?assertNotEqual(Pid1, Pid3),
    ?assertNotEqual(Pid2, Pid3),
    %% Tripping (sonnet-4-6, propose_merge) leaves the others alone
    openrouter_circuit_breaker:record_failure(Pid1),
    openrouter_circuit_breaker:record_failure(Pid1),
    openrouter_circuit_breaker:record_failure(Pid1),
    ?assertEqual(open, openrouter_circuit_breaker:state(Pid1)),
    ?assertEqual(closed, openrouter_circuit_breaker:state(Pid2)),
    ?assertEqual(closed, openrouter_circuit_breaker:state(Pid3)).

per_op_opts_override_per_model(_Config) ->
    application:set_env(erl_openrouter,
                        per_model_circuit_breaker_opts,
                        #{<<"sonnet-4-6">> => #{failure_threshold => 10}}),
    application:set_env(erl_openrouter,
                        per_op_circuit_breaker_opts,
                        #{propose_merge => #{failure_threshold => 2}}),
    Pid = openrouter_circuit_breaker_sup:ensure(<<"sonnet-4-6">>, propose_merge),
    %% per_op layer wins -- threshold 2, not 10
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    ?assertEqual(open, openrouter_circuit_breaker:state(Pid)).

per_model_op_opts_override_per_op(_Config) ->
    application:set_env(erl_openrouter,
                        per_op_circuit_breaker_opts,
                        #{propose_merge => #{failure_threshold => 5},
                          {<<"sonnet-4-6">>, propose_merge} =>
                              #{failure_threshold => 2}}),
    Pid = openrouter_circuit_breaker_sup:ensure(<<"sonnet-4-6">>, propose_merge),
    %% Combined-key layer wins -- threshold 2
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    ?assertEqual(open, openrouter_circuit_breaker:state(Pid)),
    %% Other op on same model uses the bare-op layer (threshold 5)
    Pid2 = openrouter_circuit_breaker_sup:ensure(<<"sonnet-4-6">>, classify_path),
    openrouter_circuit_breaker:record_failure(Pid2),
    openrouter_circuit_breaker:record_failure(Pid2),
    ?assertEqual(closed, openrouter_circuit_breaker:state(Pid2)).

telemetry_includes_op(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    Ref = proplists:get_value(tel_ref, Config),
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    receive
        {Ref, #{from := closed, to := open, model := Model, op := Op}} ->
            ?assertEqual(<<"test/model-a">>, Model),
            ?assertEqual(propose_merge, Op)
    after 1000 ->
        ct:fail("no telemetry event received for closed->open")
    end.

%%====================================================================
%% Broken-world ratio scenarios
%%====================================================================

%% The 17:08 replay: bursty failures with interleaved sibling
%% successes. The legacy consecutive-count breaker would not trip
%% because the success resets the counter. The ratio breaker
%% should trip because total failures dominate the window.
ratio_trips_on_bursty_failures_with_interleaved_successes(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    %% Pattern: F F F F S F F F F (4/9 = 0.44) -- below 0.5 threshold
    Failures1 = 4,
    [openrouter_circuit_breaker:record_failure(Pid)
     || _ <- lists:seq(1, Failures1)],
    openrouter_circuit_breaker:record_success(Pid),
    [openrouter_circuit_breaker:record_failure(Pid)
     || _ <- lists:seq(1, Failures1)],
    %% Now 8/9, ratio 0.89 -- past the 0.5 threshold
    ?assertEqual(open, openrouter_circuit_breaker:state(Pid)).

%% Regression guard: the legacy consecutive-count code path must
%% still NOT trip on this same pattern. Proves the algorithm
%% switch is the differentiator and we preserved old behavior for
%% callers that don't opt in to ratio.
legacy_consecutive_does_not_trip_with_interleaved_successes(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    %% Same pattern as above but consecutive-count config
    [openrouter_circuit_breaker:record_failure(Pid) || _ <- lists:seq(1, 4)],
    openrouter_circuit_breaker:record_success(Pid),
    [openrouter_circuit_breaker:record_failure(Pid) || _ <- lists:seq(1, 4)],
    %% Threshold is 5, longest consecutive run was 4 -- never tripped
    ?assertEqual(closed, openrouter_circuit_breaker:state(Pid)).

%% Below min_attempts the breaker stays closed even at 100% failure
%% rate. Prevents tripping on tiny samples right after restart.
ratio_min_attempts_gates_trip(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    %% min_attempts=4 in opts; only send 3 failures
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    openrouter_circuit_breaker:record_failure(Pid),
    ?assertEqual(closed, openrouter_circuit_breaker:state(Pid)),
    %% Fourth failure crosses the gate
    openrouter_circuit_breaker:record_failure(Pid),
    ?assertEqual(open, openrouter_circuit_breaker:state(Pid)).

%% Old failures age out of the window. Clean successes after the
%% window expires should not be poisoned by stale failures.
ratio_window_age_expiry_recovers(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    %% Three failures (below min_attempts=4) so we don't trip yet
    [openrouter_circuit_breaker:record_failure(Pid) || _ <- lists:seq(1, 3)],
    ?assertEqual(closed, openrouter_circuit_breaker:state(Pid)),
    %% Wait past window_max_ms (150ms in test opts)
    timer:sleep(200),
    %% Successes after expiry should not trip; window is empty
    [openrouter_circuit_breaker:record_success(Pid) || _ <- lists:seq(1, 5)],
    ?assertEqual(closed, openrouter_circuit_breaker:state(Pid)).

%% After tripping, transitioning open -> half_open -> closed should
%% leave the breaker fresh; the burst that tripped it should not
%% poison the post-recovery window.
ratio_burst_then_quiet_does_not_re_trip(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    %% 4 failures cross min_attempts=4 with ratio 1.0
    [openrouter_circuit_breaker:record_failure(Pid) || _ <- lists:seq(1, 4)],
    ?assertEqual(open, openrouter_circuit_breaker:state(Pid)),
    %% Wait for half_open + probe success
    timer:sleep(150),
    ?assertEqual(half_open, openrouter_circuit_breaker:state(Pid)),
    openrouter_circuit_breaker:record_success(Pid),
    ?assertEqual(closed, openrouter_circuit_breaker:state(Pid)),
    %% Three more failures should NOT trip -- window was cleared on
    %% the closed transition. Below min_attempts=4 again.
    [openrouter_circuit_breaker:record_failure(Pid) || _ <- lists:seq(1, 3)],
    ?assertEqual(closed, openrouter_circuit_breaker:state(Pid)).

%% A failed half_open probe re-opens the breaker. The window was
%% cleared on the original trip; the half_open -> open path does
%% not touch the window or failure counter. After eventual recovery
%% to closed, the post-recovery sample budget should be fresh.
ratio_half_open_reopen_keeps_window_clean(Config) ->
    Pid = proplists:get_value(cb_pid, Config),
    %% Trip via 4 failures (min_attempts=4, ratio=0.5)
    [openrouter_circuit_breaker:record_failure(Pid) || _ <- lists:seq(1, 4)],
    ?assertEqual(open, openrouter_circuit_breaker:state(Pid)),
    %% Wait for half_open
    timer:sleep(150),
    ?assertEqual(half_open, openrouter_circuit_breaker:state(Pid)),
    %% Probe fails -> back to open
    openrouter_circuit_breaker:record_failure(Pid),
    ?assertEqual(open, openrouter_circuit_breaker:state(Pid)),
    %% Wait for half_open again
    timer:sleep(150),
    ?assertEqual(half_open, openrouter_circuit_breaker:state(Pid)),
    %% Probe succeeds -> closed
    openrouter_circuit_breaker:record_success(Pid),
    ?assertEqual(closed, openrouter_circuit_breaker:state(Pid)),
    %% Three new failures (one below min_attempts=4) must NOT trip.
    %% A poisoned window from the prior cycle would reach min_attempts
    %% and trip immediately.
    [openrouter_circuit_breaker:record_failure(Pid) || _ <- lists:seq(1, 3)],
    ?assertEqual(closed, openrouter_circuit_breaker:state(Pid)).

%%====================================================================
%% Helpers
%%====================================================================

%% Per-test ratio opts. Window is short (150ms) so age-expiry tests
%% don't sleep too long.
ratio_opts_for(ratio_trips_on_bursty_failures_with_interleaved_successes) ->
    #{failure_ratio => 0.5,
      min_attempts => 4,
      window_max_ms => 60000,
      window_max_size => 50,
      reset_timeout => 100};
ratio_opts_for(ratio_min_attempts_gates_trip) ->
    #{failure_ratio => 0.5,
      min_attempts => 4,
      window_max_ms => 60000,
      window_max_size => 50,
      reset_timeout => 100};
ratio_opts_for(ratio_window_age_expiry_recovers) ->
    #{failure_ratio => 0.5,
      min_attempts => 4,
      window_max_ms => 150,
      window_max_size => 50,
      reset_timeout => 100};
ratio_opts_for(ratio_burst_then_quiet_does_not_re_trip) ->
    #{failure_ratio => 0.5,
      min_attempts => 4,
      window_max_ms => 60000,
      window_max_size => 50,
      reset_timeout => 100};
ratio_opts_for(ratio_half_open_reopen_keeps_window_clean) ->
    #{failure_ratio => 0.5,
      min_attempts => 4,
      window_max_ms => 60000,
      window_max_size => 50,
      reset_timeout => 100}.
