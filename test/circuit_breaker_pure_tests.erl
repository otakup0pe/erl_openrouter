-module(circuit_breaker_pure_tests).
-include_lib("eunit/include/eunit.hrl").

%% Pure-function coverage for the circuit breaker. Anything that does
%% not need a live gen_server lives here -- the SUITE handles
%% lifecycle / supervisor / telemetry coverage.

%%--------------------------------------------------------------------
%% prune_window/3
%%--------------------------------------------------------------------

prune_drops_entries_older_than_min_ts_test() ->
    Q0 = queue:from_list([{100, failure}, {200, failure}, {300, success}]),
    Q1 = openrouter_circuit_breaker:prune_window(Q0, 250, 100),
    ?assertEqual([{300, success}], queue:to_list(Q1)).

prune_keeps_entries_at_min_ts_boundary_test() ->
    %% MinTs is exclusive of older entries -- equal timestamps survive
    Q0 = queue:from_list([{100, failure}, {200, failure}]),
    Q1 = openrouter_circuit_breaker:prune_window(Q0, 200, 100),
    ?assertEqual([{200, failure}], queue:to_list(Q1)).

prune_caps_size_dropping_oldest_first_test() ->
    Q0 = queue:from_list([{1, success}, {2, failure}, {3, success}, {4, failure}]),
    Q1 = openrouter_circuit_breaker:prune_window(Q0, 0, 2),
    %% Oldest two dropped, newest two retained, order preserved
    ?assertEqual([{3, success}, {4, failure}], queue:to_list(Q1)).

prune_no_op_when_within_bounds_test() ->
    Q0 = queue:from_list([{100, success}, {200, failure}]),
    Q1 = openrouter_circuit_breaker:prune_window(Q0, 50, 10),
    ?assertEqual(queue:to_list(Q0), queue:to_list(Q1)).

prune_empty_window_test() ->
    Q0 = queue:new(),
    Q1 = openrouter_circuit_breaker:prune_window(Q0, 0, 10),
    ?assertEqual([], queue:to_list(Q1)).

prune_combined_age_and_size_test() ->
    %% Both age limit and size cap apply -- size cap wins because age
    %% leaves three entries but size cap is two
    Q0 = queue:from_list([{100, failure}, {200, failure}, {300, success}, {400, failure}]),
    Q1 = openrouter_circuit_breaker:prune_window(Q0, 150, 2),
    ?assertEqual([{300, success}, {400, failure}], queue:to_list(Q1)).

%%--------------------------------------------------------------------
%% failure_ratio_of/1
%%--------------------------------------------------------------------

ratio_empty_window_is_zero_test() ->
    Q = queue:new(),
    ?assertEqual(0.0, openrouter_circuit_breaker:failure_ratio_of(Q)).

ratio_all_failures_test() ->
    Q = queue:from_list([{1, failure}, {2, failure}, {3, failure}]),
    ?assertEqual(1.0, openrouter_circuit_breaker:failure_ratio_of(Q)).

ratio_all_successes_test() ->
    Q = queue:from_list([{1, success}, {2, success}]),
    ?assertEqual(0.0, openrouter_circuit_breaker:failure_ratio_of(Q)).

ratio_mixed_outcomes_test() ->
    %% 3 failures of 5 = 0.6
    Q = queue:from_list([
        {1, failure}, {2, success}, {3, failure}, {4, success}, {5, failure}
    ]),
    ?assertEqual(0.6, openrouter_circuit_breaker:failure_ratio_of(Q)).

%%--------------------------------------------------------------------
%% should_trip_ratio/4
%%--------------------------------------------------------------------

trip_below_min_attempts_does_not_trip_test() ->
    %% 100% failure rate but only 3 samples, min=5
    Q = queue:from_list([{1, failure}, {2, failure}, {3, failure}]),
    Total = queue:len(Q),
    ?assertNot(openrouter_circuit_breaker:should_trip_ratio(Q, 5, 0.5, Total)).

trip_at_exact_ratio_threshold_test() ->
    %% 5/10 = 0.5, threshold 0.5 -- should trip (>=)
    Q = queue:from_list([
        {1, failure}, {2, failure}, {3, failure}, {4, failure}, {5, failure},
        {6, success}, {7, success}, {8, success}, {9, success}, {10, success}
    ]),
    Total = queue:len(Q),
    ?assert(openrouter_circuit_breaker:should_trip_ratio(Q, 5, 0.5, Total)).

trip_below_ratio_threshold_test() ->
    %% 4/10 = 0.4, threshold 0.5 -- below
    Q = queue:from_list([
        {1, failure}, {2, failure}, {3, failure}, {4, failure},
        {5, success}, {6, success}, {7, success}, {8, success},
        {9, success}, {10, success}
    ]),
    Total = queue:len(Q),
    ?assertNot(openrouter_circuit_breaker:should_trip_ratio(Q, 5, 0.5, Total)).

trip_above_ratio_threshold_test() ->
    %% 8/9 = 0.89, threshold 0.5 -- the 17:08 scenario shape
    Q = queue:from_list([
        {1, failure}, {2, failure}, {3, success}, {4, failure}, {5, failure},
        {6, failure}, {7, failure}, {8, failure}, {9, failure}
    ]),
    Total = queue:len(Q),
    ?assert(openrouter_circuit_breaker:should_trip_ratio(Q, 4, 0.5, Total)).

trip_empty_window_does_not_trip_test() ->
    Q = queue:new(),
    ?assertNot(openrouter_circuit_breaker:should_trip_ratio(Q, 5, 0.5, 0)).

%%--------------------------------------------------------------------
%% breaker_opts/2 -- layered precedence
%%
%% Regression coverage: foldl + maps:merge/2 is easy to get backwards
%% (Element-vs-Acc order), and silently wrong since the merge still
%% returns a valid map. These tests pin the precedence to:
%%   default < per_model < per_op < per_(model, op).
%%--------------------------------------------------------------------

opts_default_only_test() ->
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 5, reset_timeout => 30000}),
    application:unset_env(erl_openrouter, per_model_circuit_breaker_opts),
    application:unset_env(erl_openrouter, per_op_circuit_breaker_opts),
    Opts = openrouter_circuit_breaker_sup:breaker_opts(<<"any">>, any_op),
    ?assertEqual(5, maps:get(failure_threshold, Opts)),
    ?assertEqual(30000, maps:get(reset_timeout, Opts)).

opts_per_model_overrides_default_test() ->
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 5, reset_timeout => 30000}),
    application:set_env(erl_openrouter, per_model_circuit_breaker_opts,
                        #{<<"hot-model">> => #{failure_threshold => 3}}),
    application:unset_env(erl_openrouter, per_op_circuit_breaker_opts),
    Opts = openrouter_circuit_breaker_sup:breaker_opts(<<"hot-model">>,
                                                       any_op),
    %% per_model wins on threshold; default carries reset_timeout
    ?assertEqual(3, maps:get(failure_threshold, Opts)),
    ?assertEqual(30000, maps:get(reset_timeout, Opts)).

opts_per_op_overrides_per_model_test() ->
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 5, reset_timeout => 30000}),
    application:set_env(erl_openrouter, per_model_circuit_breaker_opts,
                        #{<<"hot-model">> => #{failure_threshold => 10}}),
    application:set_env(erl_openrouter, per_op_circuit_breaker_opts,
                        #{propose_merge => #{failure_threshold => 2}}),
    Opts = openrouter_circuit_breaker_sup:breaker_opts(<<"hot-model">>,
                                                       propose_merge),
    %% per_op (2) wins over per_model (10) and default (5)
    ?assertEqual(2, maps:get(failure_threshold, Opts)).

opts_per_model_op_overrides_per_op_test() ->
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 5}),
    application:unset_env(erl_openrouter, per_model_circuit_breaker_opts),
    application:set_env(erl_openrouter, per_op_circuit_breaker_opts,
                        #{propose_merge => #{failure_threshold => 3},
                          {<<"sonnet-4-6">>, propose_merge} =>
                              #{failure_threshold => 1}}),
    Opts = openrouter_circuit_breaker_sup:breaker_opts(<<"sonnet-4-6">>,
                                                       propose_merge),
    %% per_(model, op) (1) wins over per_op (3) and default (5)
    ?assertEqual(1, maps:get(failure_threshold, Opts)).

opts_layers_compose_distinct_keys_test() ->
    %% Different layers contribute different keys; merge should
    %% accumulate rather than truncate.
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 5, reset_timeout => 30000}),
    application:set_env(erl_openrouter, per_op_circuit_breaker_opts,
                        #{propose_merge =>
                              #{failure_ratio => 0.5,
                                window_max_ms => 60000,
                                min_attempts => 4}}),
    application:unset_env(erl_openrouter, per_model_circuit_breaker_opts),
    Opts = openrouter_circuit_breaker_sup:breaker_opts(<<"any">>,
                                                       propose_merge),
    ?assertEqual(5, maps:get(failure_threshold, Opts)),
    ?assertEqual(30000, maps:get(reset_timeout, Opts)),
    ?assertEqual(0.5, maps:get(failure_ratio, Opts)),
    ?assertEqual(60000, maps:get(window_max_ms, Opts)),
    ?assertEqual(4, maps:get(min_attempts, Opts)).
