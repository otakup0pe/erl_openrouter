-module(manual_integration_SUITE).

%% Integration tests against the real OpenRouter API.
%%
%% Gated on the OPENROUTER_API_KEY environment variable. When the
%% variable is absent every group returns {skip, ...} so the suite
%% is safe to include in CI without credentials.
%%
%% Uses a hardcoded known-cheap model for reliability.

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

-define(TEST_MODEL, <<"meta-llama/llama-3.1-8b-instruct">>).

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    chat_basic/1,
    chat_with_model/1,
    models_list/1,
    key_info/1,
    bad_api_key/1,
    invalid_model/1,
    tool_call_roundtrip/1,
    local_rate_limit/1,
    concurrent_requests/1
]).

-define(MAX_TOKENS, 50).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [{group, happy_path},
     {group, error_handling},
     {group, tool_use},
     {group, resilience},
     {group, concurrency}].

groups() ->
    [{happy_path, [parallel], [
        chat_basic,
        chat_with_model,
        models_list,
        key_info
    ]},
     {error_handling, [sequence], [
        bad_api_key,
        invalid_model
    ]},
     {tool_use, [], [
        tool_call_roundtrip
    ]},
     {resilience, [], [
        local_rate_limit
     ]},
     {concurrency, [], [
        concurrent_requests
     ]}].

init_per_suite(Config) ->
    case os:getenv("OPENROUTER_API_KEY") of
        false ->
            {skip, "OPENROUTER_API_KEY not set"};
        "" ->
            {skip, "OPENROUTER_API_KEY not set"};
        _Key ->
            ok = application:ensure_started(inets),
            ok = application:ensure_started(crypto),
            ok = application:ensure_started(asn1),
            ok = application:ensure_started(public_key),
            ok = application:ensure_started(ssl),
            {ok, _} = application:ensure_all_started(erl_openrouter),
            ct:pal("Using free model: ~s", [?TEST_MODEL]),
            [{test_model, ?TEST_MODEL} | Config]
    end.

end_per_suite(_Config) ->
    application:stop(erl_openrouter),
    ok.

init_per_group(error_handling, Config) ->
    Config;
init_per_group(_Group, Config) ->
    %% Ensure openrouter_client is alive before each group.
    %% The error_handling group may leave it in a bad state.
    case whereis(openrouter_client) of
        undefined -> restore_default_client();
        _ -> ok
    end,
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(bad_api_key, Config) ->
    %% Stop the default client via supervisor so it doesn't auto-restart
    ok = supervisor:terminate_child(openrouter_sup, openrouter_client),
    ok = supervisor:delete_child(openrouter_sup, openrouter_client),
    Config;
init_per_testcase(local_rate_limit, Config) ->
    %% Stop the supervised rate limiter so it doesn't auto-restart
    ok = supervisor:terminate_child(openrouter_sup, openrouter_rate_limiter),
    ok = supervisor:delete_child(openrouter_sup, openrouter_rate_limiter),
    %% Start a test-specific one with tight limits
    {ok, _} = openrouter_rate_limiter:start_link(
        openrouter_rate_limiter,
        #{max_tokens => 2, refill_interval => 60000}),
    Config;
init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(bad_api_key, _Config) ->
    %% Restore the default client under the supervisor
    restore_default_client(),
    ok;
end_per_testcase(local_rate_limit, _Config) ->
    %% Kill the test rate limiter
    ok = stop_rate_limiter(),
    %% Restore the default one under the supervisor
    RateLimiterOpts = application:get_env(erl_openrouter, rate_limiter_opts,
                                          #{max_tokens => 60,
                                            refill_interval => 60000}),
    ChildSpec = #{id => openrouter_rate_limiter,
                  start => {openrouter_rate_limiter, start_link,
                            [openrouter_rate_limiter, RateLimiterOpts]},
                  restart => permanent,
                  type => worker},
    case supervisor:start_child(openrouter_sup, ChildSpec) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, already_present} ->
            case supervisor:restart_child(openrouter_sup, openrouter_rate_limiter) of
                {ok, _} -> ok;
                {error, running} -> ok
            end
    end,
    ok;
end_per_testcase(_TC, _Config) ->
    ok.

%%====================================================================
%% happy_path group
%%====================================================================

chat_basic(Config) ->
    Model = proplists:get_value(test_model, Config),
    Messages = [#{<<"role">> => <<"user">>,
                  <<"content">> => <<"Say hello in one word.">>}],
    Opts = #{model => Model, max_tokens => ?MAX_TOKENS},
    Result = openrouter:chat(Messages, Opts),
    ?assertMatch({ok, #chat_response{}}, Result),
    {ok, Resp} = Result,
    ?assertNotEqual(undefined, Resp#chat_response.id),
    [Choice | _] = Resp#chat_response.choices,
    Content = maps:get(<<"content">>, maps:get(<<"message">>, Choice)),
    ?assert(is_binary(Content) andalso byte_size(Content) > 0).

chat_with_model(Config) ->
    Model = proplists:get_value(test_model, Config),
    Messages = [#{<<"role">> => <<"user">>,
                  <<"content">> => <<"Reply with the word OK.">>}],
    Opts = #{model => Model, max_tokens => ?MAX_TOKENS},
    {ok, Resp} = openrouter:chat(Messages, Opts),
    RespModel = Resp#chat_response.model,
    ?assert(is_binary(RespModel)),
    ct:pal("Requested model: ~s, response model: ~s", [Model, RespModel]).

models_list(_Config) ->
    Result = openrouter:models(),
    ?assertMatch({ok, _}, Result),
    {ok, Models} = Result,
    ?assert(is_list(Models)),
    ?assert(length(Models) > 0),
    [First | _] = Models,
    ?assert(is_map(First)),
    ?assertMatch(#{<<"id">> := _}, First).

key_info(_Config) ->
    Result = openrouter:key_info(),
    ?assertMatch({ok, _}, Result),
    {ok, Info} = Result,
    ?assert(is_map(Info)),
    %% Log non-sensitive fields only
    ct:pal("Key info: is_free_tier=~p, usage=~p",
           [maps:get(<<"is_free_tier">>, Info, unknown),
            maps:get(<<"usage">>, Info, unknown)]).

%%====================================================================
%% error_handling group
%%====================================================================

bad_api_key(_Config) ->
    %% Default client was removed from supervisor in init_per_testcase.
    %% Start a fresh one with garbage auth. The bad auth_callback must
    %% be in BOTH the client opts AND the per-request opts, because
    %% resolve_request_auth checks per-request opts first and falls
    %% through to OPENROUTER_API_KEY env var if not found.
    BadAuth = fun() -> {ok, <<"sk-garbage-invalid-key-00000">>} end,
    BadOpts = #{auth_callback => BadAuth},
    {ok, Pid} = openrouter_client:start_link(BadOpts),
    unlink(Pid),
    Messages = [#{<<"role">> => <<"user">>,
                  <<"content">> => <<"Hi">>}],
    Opts = #{model => <<"anthropic/claude-3-haiku">>,
             max_tokens => ?MAX_TOKENS,
             auth_callback => BadAuth},
    Result = openrouter:chat(Messages, Opts),
    gen_server:stop(Pid),
    ct:pal("bad_api_key result type: ~p", [
        case Result of
            {error, #api_error{type = T}} -> T;
            Other -> Other
        end]),
    ?assertMatch({error, #api_error{type = auth_error}}, Result).

invalid_model(_Config) ->
    Messages = [#{<<"role">> => <<"user">>,
                  <<"content">> => <<"Hi">>}],
    Opts = #{model => <<"nonexistent/model-xyz">>, max_tokens => ?MAX_TOKENS},
    Result = openrouter:chat(Messages, Opts),
    ct:pal("invalid_model result type: ~p", [
        case Result of
            {error, #api_error{type = T}} -> T;
            Other -> Other
        end]),
    ?assertMatch({error, _}, Result).

%%====================================================================
%% tool_use group
%%====================================================================

tool_call_roundtrip(Config) ->
    Model = proplists:get_value(test_model, Config),
    WeatherTool = #{
        <<"type">> => <<"function">>,
        <<"function">> => #{
            <<"name">> => <<"get_weather">>,
            <<"description">> => <<"Get the current weather for a city.">>,
            <<"parameters">> => #{
                <<"type">> => <<"object">>,
                <<"properties">> => #{
                    <<"city">> => #{
                        <<"type">> => <<"string">>,
                        <<"description">> => <<"City name">>
                    }
                },
                <<"required">> => [<<"city">>]
            }
        }
    },
    Messages = [#{<<"role">> => <<"user">>,
                  <<"content">> => <<"What is the weather in Tokyo?">>}],
    Opts = #{model => Model,
             max_tokens => ?MAX_TOKENS,
             tools => [WeatherTool],
             tool_choice => auto},
    {ok, Resp1} = openrouter:chat(Messages, Opts),
    [Choice1 | _] = Resp1#chat_response.choices,
    FinishReason1 = maps:get(<<"finish_reason">>, Choice1, undefined),
    AssistantMsg = maps:get(<<"message">>, Choice1),
    ToolCalls = maps:get(<<"tool_calls">>, AssistantMsg, []),
    case ToolCalls of
        [] ->
            ct:pal("Model did not issue tool_calls (finish_reason=~p), skipping follow-up.",
                   [FinishReason1]),
            ok;
        [TC | _] ->
            ToolCallId = maps:get(<<"id">>, TC),
            ToolResult = openrouter_tools:encode_tool_result_message(
                ToolCallId,
                <<"{\"temperature\": \"22C\", \"condition\": \"sunny\"}">>),
            FollowUpMessages = Messages ++ [AssistantMsg, ToolResult],
            FollowUpOpts = #{model => Model,
                             max_tokens => ?MAX_TOKENS,
                             tools => [WeatherTool]},
            {ok, Resp2} = openrouter:chat(FollowUpMessages, FollowUpOpts),
            [Choice2 | _] = Resp2#chat_response.choices,
            FinishReason2 = maps:get(<<"finish_reason">>, Choice2, undefined),
            ct:pal("Follow-up finish_reason: ~p", [FinishReason2]),
            ?assert(FinishReason2 =:= <<"stop">> orelse
                    FinishReason2 =:= <<"tool_calls">>)
    end.

%%====================================================================
%% resilience group
%%====================================================================

local_rate_limit(Config) ->
    Model = proplists:get_value(test_model, Config),
    Messages = [#{<<"role">> => <<"user">>,
                  <<"content">> => <<"Say hi.">>}],
    Opts = #{model => Model, max_tokens => ?MAX_TOKENS},
    {ok, _} = openrouter:chat(Messages, Opts),
    {ok, _} = openrouter:chat(Messages, Opts),
    Result3 = openrouter:chat(Messages, Opts),
    ?assertMatch({error, #api_error{type = rate_limited}}, Result3),
    {error, #api_error{metadata = Meta}} = Result3,
    ?assertEqual(local, maps:get(source, Meta, undefined)).

%%====================================================================
%% concurrency group
%%====================================================================

concurrent_requests(Config) ->
    Model = proplists:get_value(test_model, Config),
    Messages = [#{<<"role">> => <<"user">>,
                  <<"content">> => <<"Reply OK.">>}],
    Opts = #{model => Model, max_tokens => ?MAX_TOKENS},
    Parent = self(),
    N = 3,
    T0 = erlang:monotonic_time(millisecond),
    Pids = [spawn_link(fun() ->
        Res = openrouter:chat(Messages, Opts),
        Parent ! {self(), Res}
    end) || _ <- lists:seq(1, N)],
    Results = [receive {Pid, Res} -> Res after 60000 -> {error, timeout} end
               || Pid <- Pids],
    T1 = erlang:monotonic_time(millisecond),
    WallMs = T1 - T0,
    ct:pal("All ~p requests completed in ~p ms.", [N, WallMs]),
    lists:foreach(fun(R) ->
        ?assertMatch({ok, #chat_response{}}, R)
    end, Results).

%%====================================================================
%% Internal helpers
%%====================================================================

restore_default_client() ->
    %% Ensure any leftover registered process is gone
    case whereis(openrouter_client) of
        undefined -> ok;
        Pid ->
            try gen_server:stop(Pid, normal, 2000)
            catch exit:{noproc, _} -> ok
            end,
            timer:sleep(100)
    end,
    %% Re-add the child spec and start it under the supervisor
    ChildSpec = #{id => openrouter_client,
                  start => {openrouter_client, start_link, []},
                  restart => permanent,
                  type => worker},
    case supervisor:start_child(openrouter_sup, ChildSpec) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, already_present} ->
            case supervisor:restart_child(openrouter_sup, openrouter_client) of
                {ok, _} -> ok;
                {error, running} -> ok
            end
    end,
    %% Verify the client is actually responding
    case whereis(openrouter_client) of
        undefined ->
            ct:fail("restore_default_client: client not running after restore");
        _ -> ok
    end.

stop_rate_limiter() ->
    case whereis(openrouter_rate_limiter) of
        undefined -> ok;
        Pid ->
            gen_server:stop(Pid),
            ok
    end.
