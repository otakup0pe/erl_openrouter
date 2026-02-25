-module(openrouter_key).

-export([parse_response/1]).

-spec parse_response(Body :: binary()) -> {ok, map()} | {error, term()}.
parse_response(Body) ->
    case openrouter_json:decode(Body) of
        {ok, #{<<"data">> := Data}} ->
            {ok, Data};
        {ok, #{<<"error">> := _} = ErrorMap} ->
            {error, openrouter_error:from_body(ErrorMap)};
        {error, Reason} ->
            {error, {parse_error, Reason}}
    end.
