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
%% global_opts/0 -- the aggregate (upstream) breaker's own config
%%
%% WHY A SEPARATE LAYER: every per-(model, op) breaker observes only
%% its own slice, so none of them can see a failure of the SHARED path
%% -- one base_url, one API key, one HTTP route. A thin failure rate
%% spread across many breakers trips none of them while every call is
%% failing. The aggregate breaker is the only thing positioned to see
%% that, and it needs ratio-over-window semantics because consecutive
%% counting is defeated by interleaved successes from healthy models.
%%
%% Defaults are deliberately HIGH ratio and LONG window: the aggregate
%% blocks ALL traffic when it opens, so it must not fire on one flaky
%% provider. Both are configurable.
%%--------------------------------------------------------------------

global_opts_defaults_are_ratio_not_consecutive_test() ->
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 5, reset_timeout => 30000}),
    Opts = openrouter_circuit_breaker_sup:global_opts(),
    %% A consecutive threshold here would make the aggregate breaker
    %% blind to exactly the spread-out failure it exists to catch.
    ?assert(is_float(maps:get(failure_ratio, Opts))),
    ?assert(maps:get(failure_ratio, Opts) >= 0.75),
    ?assert(maps:get(window_max_ms, Opts) >= 300000),
    ?assert(maps:get(min_attempts, Opts) >= 10).

global_opts_ratio_is_configurable_test() ->
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 5, reset_timeout => 30000,
                          global => #{failure_ratio => 0.6}}),
    Opts = openrouter_circuit_breaker_sup:global_opts(),
    ?assertEqual(0.6, maps:get(failure_ratio, Opts)).

global_opts_window_is_configurable_test() ->
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 5, reset_timeout => 30000,
                          global => #{window_max_ms => 900000,
                                      min_attempts => 25}}),
    Opts = openrouter_circuit_breaker_sup:global_opts(),
    ?assertEqual(900000, maps:get(window_max_ms, Opts)),
    ?assertEqual(25, maps:get(min_attempts, Opts)).

global_opts_overrides_top_level_test() ->
    %% Same Element-vs-Acc merge-order hazard the breaker_opts tests
    %% below pin: a backwards merge still yields a valid map.
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{reset_timeout => 30000,
                          global => #{reset_timeout => 120000}}),
    Opts = openrouter_circuit_breaker_sup:global_opts(),
    ?assertEqual(120000, maps:get(reset_timeout, Opts)).

global_opts_strips_per_model_and_per_op_test() ->
    %% The aggregate breaker is not scoped to any model or op, so
    %% inheriting those sub-maps would hand a gen_server init a key it
    %% cannot interpret.
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 5, reset_timeout => 30000,
                          per_model => #{<<"m">> => #{failure_threshold => 2}},
                          per_op => #{some_op => #{failure_threshold => 3}},
                          global => #{failure_ratio => 0.8}}),
    Opts = openrouter_circuit_breaker_sup:global_opts(),
    ?assertNot(maps:is_key(per_model, Opts)),
    ?assertNot(maps:is_key(per_op, Opts)),
    ?assertNot(maps:is_key(global, Opts)).

global_opts_consecutive_threshold_is_cleared_test() ->
    %% should_trip/1 dispatches on failure_ratio =:= undefined FIRST,
    %% so a surviving failure_threshold alongside a ratio is ambiguous
    %% at the clause level. The ratio clause must be the one that
    %% matches.
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 5, reset_timeout => 30000,
                          global => #{failure_ratio => 0.8}}),
    Opts = openrouter_circuit_breaker_sup:global_opts(),
    ?assertEqual(undefined, maps:get(failure_threshold, Opts, undefined)).

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
    Opts = openrouter_circuit_breaker_sup:breaker_opts(<<"any">>, any_op),
    ?assertEqual(5, maps:get(failure_threshold, Opts)),
    ?assertEqual(30000, maps:get(reset_timeout, Opts)).

opts_per_model_overrides_default_test() ->
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 5, reset_timeout => 30000,
                          per_model =>
                              #{<<"hot-model">> =>
                                    #{failure_threshold => 3}}}),
    Opts = openrouter_circuit_breaker_sup:breaker_opts(<<"hot-model">>,
                                                       any_op),
    %% per_model wins on threshold; default carries reset_timeout
    ?assertEqual(3, maps:get(failure_threshold, Opts)),
    ?assertEqual(30000, maps:get(reset_timeout, Opts)).

opts_per_op_overrides_per_model_test() ->
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 5, reset_timeout => 30000,
                          per_model =>
                              #{<<"hot-model">> =>
                                    #{failure_threshold => 10}},
                          per_op =>
                              #{propose_merge =>
                                    #{failure_threshold => 2}}}),
    Opts = openrouter_circuit_breaker_sup:breaker_opts(<<"hot-model">>,
                                                       propose_merge),
    %% per_op (2) wins over per_model (10) and default (5)
    ?assertEqual(2, maps:get(failure_threshold, Opts)).

opts_per_model_op_overrides_per_op_test() ->
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 5,
                          per_op =>
                              #{propose_merge =>
                                    #{failure_threshold => 3},
                                {<<"sonnet-4-6">>, propose_merge} =>
                                    #{failure_threshold => 1}}}),
    Opts = openrouter_circuit_breaker_sup:breaker_opts(<<"sonnet-4-6">>,
                                                       propose_merge),
    %% per_(model, op) (1) wins over per_op (3) and default (5)
    ?assertEqual(1, maps:get(failure_threshold, Opts)).

opts_layers_compose_distinct_keys_test() ->
    %% Different layers contribute different keys; merge should
    %% accumulate rather than truncate.
    application:set_env(erl_openrouter, circuit_breaker_opts,
                        #{failure_threshold => 5, reset_timeout => 30000,
                          per_op =>
                              #{propose_merge =>
                                    #{failure_ratio => 0.5,
                                      window_max_ms => 60000,
                                      min_attempts => 4}}}),
    Opts = openrouter_circuit_breaker_sup:breaker_opts(<<"any">>,
                                                       propose_merge),
    ?assertEqual(5, maps:get(failure_threshold, Opts)),
    ?assertEqual(30000, maps:get(reset_timeout, Opts)),
    ?assertEqual(0.5, maps:get(failure_ratio, Opts)),
    ?assertEqual(60000, maps:get(window_max_ms, Opts)),
    ?assertEqual(4, maps:get(min_attempts, Opts)).
