-module(openrouter_http).
%% @private
%% Internal module -- use {@link openrouter} for the public API.

-export([get/3, get/4, post/4, post/5, post_stream/5]).
-export([headers/1, headers/2]).
-export([parse_retry_after/1]).
-export([find_request_id/1]).

-type extra_header() :: {string(), string()}.
-type extra_headers() :: [extra_header()].
-type resp_headers() :: [{string(), string()}].

-export_type([extra_header/0, extra_headers/0, resp_headers/0]).

-spec get(Url :: string(), Auth :: term(), Timeout :: pos_integer()) ->
    {ok, integer(), resp_headers(), binary()} | {error, term()}.
get(Url, Auth, Timeout) ->
    get(Url, Auth, Timeout, []).

-spec get(Url :: string(), Auth :: term(), Timeout :: pos_integer(),
          ExtraHeaders :: extra_headers()) ->
    {ok, integer(), resp_headers(), binary()} | {error, term()}.
get(Url, Auth, Timeout, ExtraHeaders) ->
    Headers = headers(Auth, ExtraHeaders),
    Request = {Url, Headers},
    case httpc:request(get, Request, [{timeout, Timeout}], [{body_format, binary}]) of
        {ok, {{_, StatusCode, _}, RespHeaders, Body}} ->
            {ok, StatusCode, RespHeaders, Body};
        {error, Reason} ->
            {error, Reason}
    end.

-spec post(Url :: string(), Body :: binary(), Auth :: term(), Timeout :: pos_integer()) ->
    {ok, integer(), resp_headers(), binary()} | {error, term()}.
post(Url, Body, Auth, Timeout) ->
    post(Url, Body, Auth, Timeout, []).

-spec post(Url :: string(), Body :: binary(), Auth :: term(), Timeout :: pos_integer(),
           ExtraHeaders :: extra_headers()) ->
    {ok, integer(), resp_headers(), binary()} | {error, term()}.
post(Url, Body, Auth, Timeout, ExtraHeaders) ->
    Headers = headers(Auth, ExtraHeaders),
    ContentType = "application/json",
    Request = {Url, Headers, ContentType, Body},
    case httpc:request(post, Request, [{timeout, Timeout}], [{body_format, binary}]) of
        {ok, {{_, StatusCode, _}, RespHeaders, RespBody}} ->
            {ok, StatusCode, RespHeaders, RespBody};
        {error, Reason} ->
            {error, Reason}
    end.

-spec post_stream(Url :: string(), Body :: binary(), Auth :: term(),
                  Timeout :: pos_integer(), ExtraHeaders :: extra_headers()) ->
    {ok, reference()} | {error, term()}.
post_stream(Url, Body, Auth, Timeout, ExtraHeaders) ->
    H = headers(Auth, ExtraHeaders),
    ContentType = "application/json",
    Request = {Url, H, ContentType, Body},
    case httpc:request(post, Request, [{timeout, Timeout}],
                       [{sync, false}, {stream, self}]) of
        {ok, RequestId} -> {ok, RequestId};
        {error, Reason} -> {error, Reason}
    end.

-spec headers(Auth :: term()) -> [{string(), string()}, ...].
headers(Auth) ->
    headers(Auth, []).

-spec headers(Auth :: term(), ExtraHeaders :: extra_headers()) ->
    [{string(), string()}, ...].
headers(Auth, ExtraHeaders) when is_list(ExtraHeaders) ->
    Base = auth_headers(Auth),
    merge_headers(Base, ExtraHeaders).

%% Parsing of Retry-After header values. Handles common cases, and
%% returns undefined for junk returns. Actual date parsing happens
%% as part of backoff calculations.
-spec parse_retry_after(resp_headers()) -> pos_integer() | undefined.
parse_retry_after(Headers) ->
    case find_header("retry-after", Headers) of
        undefined -> undefined;
        Value ->
            Trimmed = string:trim(Value),
            try list_to_integer(Trimmed) of
                N when N > 0 -> N;
                _ -> undefined
            catch
                error:badarg -> undefined
            end
    end.

-spec find_request_id(resp_headers()) -> binary() | undefined.
find_request_id(Headers) ->
    case find_header("x-request-id", Headers) of
        undefined -> undefined;
        Value when is_list(Value) -> list_to_binary(Value);
        Value when is_binary(Value) -> Value
    end.

find_header(_Name, []) -> undefined;
find_header(Name, [{Key, Value} | Rest]) ->
    case string:to_lower(Key) =:= Name of
        true -> Value;
        false -> find_header(Name, Rest)
    end.

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
