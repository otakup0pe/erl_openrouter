-module(openrouter_embeddings).
%% @private
%% Internal module -- use {@link openrouter} for the public API.

-include("openrouter.hrl").

-export([build_request/2, parse_response/1]).

-spec build_request(Input :: binary() | [binary()], Opts :: map()) -> binary().
build_request(Input, Opts) ->
    Base = #{<<"input">> => Input},
    WithModel = maybe_set(<<"model">>, model, Opts, Base),
    WithDims = maybe_set(<<"dimensions">>, dimensions, Opts, WithModel),
    WithEncoding = maybe_set(<<"encoding_format">>, encoding_format, Opts, WithDims),
    WithProvider = maybe_set(<<"provider">>, provider, Opts, WithEncoding),
    {ok, Json} = openrouter_json:encode(WithProvider),
    Json.

-spec parse_response(Body :: binary()) ->
    {ok, #embedding_response{}} | {error, term()}.
parse_response(Body) ->
    case openrouter_json:decode(Body) of
        {ok, #{<<"error">> := _} = ErrorMap} ->
            {error, openrouter_error:from_body(ErrorMap)};
        {ok, #{<<"data">> := DataList} = Map} ->
            Embeddings = lists:map(fun(Item) ->
                #{index => maps:get(<<"index">>, Item, 0),
                  embedding => maps:get(<<"embedding">>, Item, [])}
            end, DataList),
            Response = #embedding_response{
                model = maps:get(<<"model">>, Map, undefined),
                data = Embeddings,
                usage = maps:get(<<"usage">>, Map, #{})
            },
            {ok, Response};
        {ok, _} ->
            {error, {parse_error, missing_data_field}};
        {error, Reason} ->
            {error, {parse_error, Reason}}
    end.

maybe_set(JsonKey, OptKey, Opts, Map) ->
    openrouter_json:maybe_set(JsonKey, OptKey, Opts, Map).
