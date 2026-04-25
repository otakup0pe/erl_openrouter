-module(usage_tests).

-include_lib("eunit/include/eunit.hrl").

usage_tracker_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_) ->
             [{"records and snapshots a single model",
               fun records_single_model/0},
              {"accumulates across multiple records",
               fun accumulates/0},
              {"separates per-model counters",
               fun multi_model/0},
              {"ignores undefined model",
               fun ignores_undefined/0},
              {"ignores non-map usage",
               fun ignores_non_map_usage/0},
              {"reset clears all counters",
               fun reset_all/0},
              {"reset of single model leaves others",
               fun reset_one/0},
              {"derives total_tokens when missing",
               fun derived_total/0}]
     end}.

setup() ->
    {ok, Pid} = openrouter_usage:start_link(),
    Pid.

cleanup(Pid) ->
    unlink(Pid),
    exit(Pid, shutdown),
    ok.

records_single_model() ->
    openrouter_usage:reset(),
    openrouter_usage:record(<<"a/b">>, #{<<"prompt_tokens">> => 10,
                                         <<"completion_tokens">> => 5,
                                         <<"total_tokens">> => 15}),
    sync(),
    ?assertEqual(#{requests => 1,
                   prompt_tokens => 10,
                   completion_tokens => 5,
                   total_tokens => 15},
                 openrouter_usage:snapshot(<<"a/b">>)).

accumulates() ->
    openrouter_usage:reset(),
    openrouter_usage:record(<<"a/b">>, #{<<"prompt_tokens">> => 10,
                                         <<"completion_tokens">> => 5,
                                         <<"total_tokens">> => 15}),
    openrouter_usage:record(<<"a/b">>, #{<<"prompt_tokens">> => 4,
                                         <<"completion_tokens">> => 6,
                                         <<"total_tokens">> => 10}),
    sync(),
    ?assertEqual(#{requests => 2,
                   prompt_tokens => 14,
                   completion_tokens => 11,
                   total_tokens => 25},
                 openrouter_usage:snapshot(<<"a/b">>)).

multi_model() ->
    openrouter_usage:reset(),
    openrouter_usage:record(<<"a/b">>, #{<<"prompt_tokens">> => 10,
                                         <<"completion_tokens">> => 5}),
    openrouter_usage:record(<<"x/y">>, #{<<"prompt_tokens">> => 7,
                                         <<"completion_tokens">> => 3}),
    sync(),
    Snap = openrouter_usage:snapshot(),
    ?assertMatch(#{<<"a/b">> := #{prompt_tokens := 10},
                   <<"x/y">> := #{prompt_tokens := 7}}, Snap).

ignores_undefined() ->
    openrouter_usage:reset(),
    openrouter_usage:record(undefined, #{<<"prompt_tokens">> => 10}),
    sync(),
    ?assertEqual(#{}, openrouter_usage:snapshot()).

ignores_non_map_usage() ->
    openrouter_usage:reset(),
    openrouter_usage:record(<<"a/b">>, undefined),
    openrouter_usage:record(<<"a/b">>, garbage),
    sync(),
    ?assertEqual(#{}, openrouter_usage:snapshot()).

reset_all() ->
    openrouter_usage:record(<<"a/b">>, #{<<"prompt_tokens">> => 10}),
    sync(),
    openrouter_usage:reset(),
    ?assertEqual(#{}, openrouter_usage:snapshot()).

reset_one() ->
    openrouter_usage:reset(),
    openrouter_usage:record(<<"a/b">>, #{<<"prompt_tokens">> => 10}),
    openrouter_usage:record(<<"x/y">>, #{<<"prompt_tokens">> => 5}),
    sync(),
    openrouter_usage:reset(<<"a/b">>),
    ?assertEqual(undefined, openrouter_usage:snapshot(<<"a/b">>)),
    ?assertMatch(#{prompt_tokens := 5}, openrouter_usage:snapshot(<<"x/y">>)).

derived_total() ->
    openrouter_usage:reset(),
    openrouter_usage:record(<<"a/b">>, #{<<"prompt_tokens">> => 10,
                                         <<"completion_tokens">> => 5}),
    sync(),
    ?assertMatch(#{total_tokens := 15}, openrouter_usage:snapshot(<<"a/b">>)).

%% Casts are async; force a synchronous round-trip so prior casts have
%% been processed.
sync() ->
    openrouter_usage:snapshot().

compute_cost_test_() ->
    [{"computes per-model and total",
      fun() ->
              Snap = #{<<"a/b">> => #{requests => 2, prompt_tokens => 100,
                                      completion_tokens => 50,
                                      total_tokens => 150}},
              Prices = #{<<"a/b">> => #{prompt => 0.001,
                                        completion => 0.002}},
              R = openrouter_usage:compute_cost(Snap, Prices),
              ?assertMatch(#{models := #{<<"a/b">> := 0.2},
                             missing_prices := [],
                             total := 0.2}, R)
      end},
     {"flags models missing from price table",
      fun() ->
              Snap = #{<<"a/b">> => #{requests => 1, prompt_tokens => 10,
                                      completion_tokens => 5,
                                      total_tokens => 15},
                       <<"x/y">> => #{requests => 1, prompt_tokens => 1,
                                      completion_tokens => 1,
                                      total_tokens => 2}},
              Prices = #{<<"a/b">> => #{prompt => 0.0, completion => 0.0}},
              R = openrouter_usage:compute_cost(Snap, Prices),
              ?assertEqual([<<"x/y">>], maps:get(missing_prices, R)),
              ?assertEqual(+0.0, maps:get(total, R))
      end},
     {"empty snapshot yields zero",
      fun() ->
              ?assertMatch(#{models := #{}, total := +0.0,
                             missing_prices := []},
                           openrouter_usage:compute_cost(#{}, #{}))
      end}].
