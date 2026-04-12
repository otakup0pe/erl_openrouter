-module(openrouter_http).

-export([get/3, post/4]).
-export([headers/1]).

-spec get(Url :: string(), Auth :: term(), Timeout :: pos_integer()) ->
    {ok, integer(), binary()} | {error, term()}.
get(Url, Auth, Timeout) ->
    Headers = headers(Auth),
    Request = {Url, Headers},
    case httpc:request(get, Request, [{timeout, Timeout}], [{body_format, binary}]) of
        {ok, {{_, StatusCode, _}, _RespHeaders, Body}} ->
            {ok, StatusCode, Body};
        {error, Reason} ->
            {error, Reason}
    end.

-spec post(Url :: string(), Body :: binary(), Auth :: term(), Timeout :: pos_integer()) ->
    {ok, integer(), binary()} | {error, term()}.
post(Url, Body, Auth, Timeout) ->
    Headers = headers(Auth),
    ContentType = "application/json",
    Request = {Url, Headers, ContentType, Body},
    case httpc:request(post, Request, [{timeout, Timeout}], [{body_format, binary}]) of
        {ok, {{_, StatusCode, _}, _RespHeaders, RespBody}} ->
            {ok, StatusCode, RespBody};
        {error, Reason} ->
            {error, Reason}
    end.

-spec headers(Auth :: term()) -> [{string(), string()}].
headers({ok, ApiKey}) ->
    [{"Authorization", "Bearer " ++ binary_to_list(ApiKey)},
     {"Content-Type", "application/json"}];
headers({error, _}) ->
    [{"Content-Type", "application/json"}];
headers(_) ->
    [{"Content-Type", "application/json"}].
