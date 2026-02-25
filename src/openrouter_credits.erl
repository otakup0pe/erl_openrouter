-module(openrouter_credits).

-include("openrouter.hrl").

-export([fetch/2]).

-spec fetch(BaseUrl :: string(), Auth :: term()) -> {ok, map()} | {error, term()}.
fetch(BaseUrl, Auth) ->
    case openrouter_http:get(BaseUrl ++ "/credits", Auth, 30000) of
        {ok, 200, Body} ->
            case openrouter_json:decode(Body) of
                {ok, #{<<"data">> := Data}} ->
                    {ok, Data};
                {ok, _} ->
                    {error, {parse_error, missing_data_field}};
                {error, Reason} ->
                    {error, {parse_error, Reason}}
            end;
        {ok, StatusCode, Body} ->
            {error, openrouter_error:classify(StatusCode, Body)};
        {error, Reason} ->
            {error, openrouter_error:classify(Reason)}
    end.
