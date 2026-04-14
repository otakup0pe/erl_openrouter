-module(openrouter_http).

-export([get/3, get/4, post/4, post/5]).
-export([headers/1, headers/2]).

-type extra_header() :: {string(), string()}.
-type extra_headers() :: [extra_header()].

-export_type([extra_header/0, extra_headers/0]).

-spec get(Url :: string(), Auth :: term(), Timeout :: pos_integer()) ->
    {ok, integer(), binary()} | {error, term()}.
get(Url, Auth, Timeout) ->
    get(Url, Auth, Timeout, []).

-spec get(Url :: string(), Auth :: term(), Timeout :: pos_integer(),
          ExtraHeaders :: extra_headers()) ->
    {ok, integer(), binary()} | {error, term()}.
get(Url, Auth, Timeout, ExtraHeaders) ->
    Headers = headers(Auth, ExtraHeaders),
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
    post(Url, Body, Auth, Timeout, []).

-spec post(Url :: string(), Body :: binary(), Auth :: term(), Timeout :: pos_integer(),
           ExtraHeaders :: extra_headers()) ->
    {ok, integer(), binary()} | {error, term()}.
post(Url, Body, Auth, Timeout, ExtraHeaders) ->
    Headers = headers(Auth, ExtraHeaders),
    ContentType = "application/json",
    Request = {Url, Headers, ContentType, Body},
    case httpc:request(post, Request, [{timeout, Timeout}], [{body_format, binary}]) of
        {ok, {{_, StatusCode, _}, _RespHeaders, RespBody}} ->
            {ok, StatusCode, RespBody};
        {error, Reason} ->
            {error, Reason}
    end.

-spec headers(Auth :: term()) -> [{string(), string()}].
headers(Auth) ->
    headers(Auth, []).

-spec headers(Auth :: term(), ExtraHeaders :: extra_headers()) ->
    [{string(), string()}].
headers(Auth, ExtraHeaders) when is_list(ExtraHeaders) ->
    Base = auth_headers(Auth),
    merge_headers(Base, ExtraHeaders).

auth_headers({ok, ApiKey}) ->
    [{"Authorization", "Bearer " ++ binary_to_list(ApiKey)},
     {"Content-Type", "application/json"}];
auth_headers({error, _}) ->
    [{"Content-Type", "application/json"}];
auth_headers(_) ->
    [{"Content-Type", "application/json"}].

merge_headers(Base, Extras) ->
    lists:foldl(fun({Name, _Value} = H, Acc) ->
                        Acc1 = remove_header(Name, Acc),
                        Acc1 ++ [H]
                end, Base, Extras).

remove_header(Name, Headers) ->
    Lower = string:to_lower(Name),
    lists:filter(fun({N, _}) -> string:to_lower(N) =/= Lower end, Headers).
