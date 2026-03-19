-module(openrouter_models).

-export([parse_response/1]).

-spec parse_response(Body :: binary()) -> {ok, [map()]} | {error, term()}.
parse_response(Body) ->
    case openrouter_json:decode(Body) of
        {ok, #{<<"data">> := Models}} ->
            {ok, Models};
        {ok, #{<<"error">> := _} = ErrorMap} ->
            {error, openrouter_error:from_body(ErrorMap)};
        {ok, _} ->
            {error, {parse_error, missing_data_field}};
        {error, Reason} ->
            {error, {parse_error, Reason}}
    end.
