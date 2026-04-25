-module(key_response_tests).
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

%% Unit tests for openrouter_key:parse_response/1.

success_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"data">> => #{
            <<"label">> => <<"My Key">>,
            <<"limit">> => 100.0,
            <<"usage">> => 42.5
        }
    }),
    {ok, Data} = openrouter_key:parse_response(Json),
    ?assertEqual(<<"My Key">>, maps:get(<<"label">>, Data)),
    ?assertEqual(100.0, maps:get(<<"limit">>, Data)).

success_with_rate_limit_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"data">> => #{
            <<"label">> => <<"Test">>,
            <<"is_free_tier">> => true,
            <<"rate_limit">> => #{<<"requests">> => 10, <<"interval">> => <<"10s">>}
        }
    }),
    {ok, Data} = openrouter_key:parse_response(Json),
    ?assertEqual(true, maps:get(<<"is_free_tier">>, Data)),
    RateLimit = maps:get(<<"rate_limit">>, Data),
    ?assertEqual(10, maps:get(<<"requests">>, RateLimit)).

error_in_body_test() ->
    {ok, Json} = openrouter_json:encode(#{
        <<"error">> => #{
            <<"code">> => 401,
            <<"message">> => <<"Invalid API key">>
        }
    }),
    {error, Error} = openrouter_key:parse_response(Json),
    ?assertEqual(auth_error, Error#api_error.type),
    ?assertEqual(<<"Invalid API key">>, Error#api_error.message).

invalid_json_test() ->
    ?assertMatch({error, {parse_error, #{raw_body := _}}},
                 openrouter_key:parse_response(<<"not json">>)).

unexpected_json_shape_test() ->
    {ok, Json} = openrouter_json:encode(#{<<"something">> => <<"else">>}),
    ?assertMatch({error, {unexpected_response, _}},
                 openrouter_key:parse_response(Json)).

html_error_page_test() ->
    Html = <<"<html><body>502 Bad Gateway</body></html>">>,
    {error, {parse_error, #{raw_body := RawBody}}} = openrouter_key:parse_response(Html),
    ?assertEqual(Html, RawBody).
