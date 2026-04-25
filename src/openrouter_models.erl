-module(openrouter_models).
%% @private
%% Internal module -- use {@link openrouter} for the public API.

-export([parse_response/1]).

-spec parse_response(Body :: binary()) -> {ok, [map()]} | {error, term()}.
parse_response(Body) ->
    case openrouter_json:decode(Body) of
        {ok, #{<<"data">> := Models}} when is_list(Models) ->
            {ok, Models};
        {ok, #{<<"error">> := _} = ErrorMap} ->
            {error, openrouter_error:from_body(ErrorMap)};
        {ok, Unexpected} ->
            {error, {unexpected_response, Unexpected}};
        {error, _DecodeError} ->
            {error, {parse_error, #{raw_body => openrouter_error:truncate_body(Body)}}}
    end.
