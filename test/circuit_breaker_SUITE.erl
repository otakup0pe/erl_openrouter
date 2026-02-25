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
    reopens_on_half_open_failure/1
]).

all() -> [{group, circuit_breaker}].

groups() ->
    [{circuit_breaker, [sequence], [
        starts_closed,
        opens_after_threshold,
        rejects_when_open,
        half_open_allows_probe,
        closes_on_success,
        reopens_on_half_open_failure
    ]}].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    {ok, Pid} = openrouter_circuit_breaker:start_link(#{
        failure_threshold => 3,
        reset_timeout => 100  %% 100ms for fast tests
    }),
    [{cb_pid, Pid} | Config].

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
