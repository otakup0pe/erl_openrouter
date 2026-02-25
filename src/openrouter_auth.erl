-module(openrouter_auth).

-export([resolve/1]).

-spec resolve(Opts :: map()) -> {ok, binary()} | {error, no_api_key}.
resolve(Opts) ->
    case resolve_from_callback(Opts) of
        {ok, Key} -> {ok, Key};
        undefined ->
            case resolve_from_app_env() of
                {ok, Key} -> {ok, Key};
                undefined ->
                    resolve_from_os_env()
            end
    end.

resolve_from_callback(#{auth_callback := Fun}) when is_function(Fun, 0) ->
    case Fun() of
        {ok, Key} when is_binary(Key) -> {ok, Key};
        Key when is_binary(Key) -> {ok, Key};
        _ -> undefined
    end;
resolve_from_callback(_) ->
    undefined.

resolve_from_app_env() ->
    case application:get_env(erl_openrouter, api_key) of
        {ok, Key} when is_binary(Key), byte_size(Key) > 0 -> {ok, Key};
        {ok, Key} when is_list(Key), length(Key) > 0 -> {ok, list_to_binary(Key)};
        _ -> undefined
    end.

resolve_from_os_env() ->
    case os:getenv("OPENROUTER_API_KEY") of
        false -> {error, no_api_key};
        "" -> {error, no_api_key};
        Key -> {ok, list_to_binary(Key)}
    end.
