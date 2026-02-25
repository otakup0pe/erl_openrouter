-module(auth_config_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tests that openrouter_auth:resolve/1 correctly resolves API keys
%% from callback, application env, and OS env in priority order.

callback_takes_priority_test() ->
    %% Set both app env and OS env, callback should win
    application:set_env(erl_openrouter, api_key, <<"app-key">>),
    os:putenv("OPENROUTER_API_KEY", "env-key"),
    Result = openrouter_auth:resolve(#{
        auth_callback => fun() -> {ok, <<"callback-key">>} end
    }),
    ?assertEqual({ok, <<"callback-key">>}, Result),
    application:unset_env(erl_openrouter, api_key),
    os:unsetenv("OPENROUTER_API_KEY").

callback_bare_binary_test() ->
    Result = openrouter_auth:resolve(#{
        auth_callback => fun() -> <<"bare-key">> end
    }),
    ?assertEqual({ok, <<"bare-key">>}, Result).

app_env_binary_test() ->
    application:set_env(erl_openrouter, api_key, <<"app-key">>),
    Result = openrouter_auth:resolve(#{}),
    ?assertEqual({ok, <<"app-key">>}, Result),
    application:unset_env(erl_openrouter, api_key).

app_env_string_test() ->
    application:set_env(erl_openrouter, api_key, "string-key"),
    Result = openrouter_auth:resolve(#{}),
    ?assertEqual({ok, <<"string-key">>}, Result),
    application:unset_env(erl_openrouter, api_key).

os_env_test() ->
    application:unset_env(erl_openrouter, api_key),
    os:putenv("OPENROUTER_API_KEY", "os-key"),
    Result = openrouter_auth:resolve(#{}),
    ?assertEqual({ok, <<"os-key">>}, Result),
    os:unsetenv("OPENROUTER_API_KEY").

no_key_available_test() ->
    application:unset_env(erl_openrouter, api_key),
    os:unsetenv("OPENROUTER_API_KEY"),
    Result = openrouter_auth:resolve(#{}),
    ?assertEqual({error, no_api_key}, Result).

empty_os_env_test() ->
    application:unset_env(erl_openrouter, api_key),
    os:putenv("OPENROUTER_API_KEY", ""),
    Result = openrouter_auth:resolve(#{}),
    ?assertEqual({error, no_api_key}, Result),
    os:unsetenv("OPENROUTER_API_KEY").

callback_returns_bad_value_falls_through_test() ->
    application:set_env(erl_openrouter, api_key, <<"fallback">>),
    Result = openrouter_auth:resolve(#{
        auth_callback => fun() -> error end
    }),
    ?assertEqual({ok, <<"fallback">>}, Result),
    application:unset_env(erl_openrouter, api_key).

app_env_priority_over_os_env_test() ->
    application:set_env(erl_openrouter, api_key, <<"app-wins">>),
    os:putenv("OPENROUTER_API_KEY", "os-loses"),
    Result = openrouter_auth:resolve(#{}),
    ?assertEqual({ok, <<"app-wins">>}, Result),
    application:unset_env(erl_openrouter, api_key),
    os:unsetenv("OPENROUTER_API_KEY").
