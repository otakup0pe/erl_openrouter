-module(mock_server_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    server_starts_and_stops/1,
    returns_default_response/1,
    returns_custom_response/1,
    returns_endpoint_specific_response/1,
    validates_auth_header/1,
    validates_content_type/1,
    tracks_request_body/1,
    tracks_request_count/1,
    custom_handler_function/1
]).

all() -> [{group, mock_server}].

groups() ->
    [{mock_server, [sequence], [
        server_starts_and_stops,
        returns_default_response,
        returns_custom_response,
        returns_endpoint_specific_response,
        validates_auth_header,
        validates_content_type,
        tracks_request_body,
        tracks_request_count,
        custom_handler_function
    ]}].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(inets),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    ok = mock_openrouter:start(),
    Port = mock_openrouter:port(),
    BaseUrl = "http://localhost:" ++ integer_to_list(Port) ++ "/api/v1",
    [{base_url, BaseUrl}, {port, Port} | Config].

end_per_testcase(_TC, _Config) ->
    mock_openrouter:stop().

%% Tests

server_starts_and_stops(Config) ->
    Port = proplists:get_value(port, Config),
    ?assert(is_integer(Port)),
    ?assert(Port > 0).

returns_default_response(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    {ok, {{_, 200, _}, _, Body}} = httpc:request(get,
        {BaseUrl ++ "/chat/completions", []}, [], [{body_format, binary}]),
    {ok, Decoded} = openrouter_json:decode(Body),
    ?assertEqual(<<"gen-mock-001">>, maps:get(<<"id">>, Decoded)).

returns_custom_response(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    {ok, CustomBody} = openrouter_json:encode(#{<<"custom">> => true}),
    mock_openrouter:set_response({200, CustomBody}),
    {ok, {{_, 200, _}, _, Body}} = httpc:request(get,
        {BaseUrl ++ "/chat/completions", []}, [], [{body_format, binary}]),
    {ok, Decoded} = openrouter_json:decode(Body),
    ?assertEqual(true, maps:get(<<"custom">>, Decoded)).

returns_endpoint_specific_response(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    {ok, ModelsBody} = openrouter_json:encode(#{<<"data">> => [#{<<"id">> => <<"test-model">>}]}),
    mock_openrouter:set_response(models, {200, ModelsBody}),
    %% chat/completions should still return default
    {ok, {{_, 200, _}, _, ChatBody}} = httpc:request(get,
        {BaseUrl ++ "/chat/completions", []}, [], [{body_format, binary}]),
    {ok, ChatDecoded} = openrouter_json:decode(ChatBody),
    ?assert(maps:is_key(<<"id">>, ChatDecoded)),
    %% models should return specific response
    {ok, {{_, 200, _}, _, ModelBody}} = httpc:request(get,
        {BaseUrl ++ "/models", []}, [], [{body_format, binary}]),
    {ok, ModelDecoded} = openrouter_json:decode(ModelBody),
    ?assert(maps:is_key(<<"data">>, ModelDecoded)).

validates_auth_header(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    Headers = [{"Authorization", "Bearer sk-test-key"}],
    {ok, {{_, 200, _}, _, _}} = httpc:request(get,
        {BaseUrl ++ "/chat/completions", Headers}, [], [{body_format, binary}]),
    #{headers := ReqHeaders} = mock_openrouter:last_request(),
    ?assertEqual(<<"Bearer sk-test-key">>, maps:get(<<"authorization">>, ReqHeaders)).

validates_content_type(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    {ok, ReqBody} = openrouter_json:encode(#{<<"messages">> => []}),
    {ok, {{_, 200, _}, _, _}} = httpc:request(post,
        {BaseUrl ++ "/chat/completions",
         [{"Authorization", "Bearer sk-test"}],
         "application/json",
         ReqBody},
        [], [{body_format, binary}]),
    #{headers := ReqHeaders} = mock_openrouter:last_request(),
    ContentType = maps:get(<<"content-type">>, ReqHeaders),
    ?assertNotEqual(nomatch, binary:match(ContentType, <<"application/json">>)).

tracks_request_body(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    {ok, ReqBody} = openrouter_json:encode(#{
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"test">>}]
    }),
    {ok, _} = httpc:request(post,
        {BaseUrl ++ "/chat/completions", [], "application/json", ReqBody},
        [], [{body_format, binary}]),
    #{body := StoredBody} = mock_openrouter:last_request(),
    {ok, Decoded} = openrouter_json:decode(StoredBody),
    ?assert(maps:is_key(<<"messages">>, Decoded)).

tracks_request_count(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    ?assertEqual(0, mock_openrouter:request_count()),
    {ok, _} = httpc:request(get,
        {BaseUrl ++ "/chat/completions", []}, [], [{body_format, binary}]),
    ?assertEqual(1, mock_openrouter:request_count()),
    {ok, _} = httpc:request(get,
        {BaseUrl ++ "/chat/completions", []}, [], [{body_format, binary}]),
    ?assertEqual(2, mock_openrouter:request_count()).

custom_handler_function(Config) ->
    BaseUrl = proplists:get_value(base_url, Config),
    mock_openrouter:set_handler(fun(_Method, _Endpoint, _Body, _Headers, Req) ->
        {ok, RespBody} = openrouter_json:encode(#{<<"handler">> => <<"custom">>}),
        Req2 = cowboy_req:reply(201,
            #{<<"content-type">> => <<"application/json">>},
            RespBody, Req),
        {ok, Req2, done}
    end),
    {ok, {{_, 201, _}, _, Body}} = httpc:request(get,
        {BaseUrl ++ "/chat/completions", []}, [], [{body_format, binary}]),
    {ok, Decoded} = openrouter_json:decode(Body),
    ?assertEqual(<<"custom">>, maps:get(<<"handler">>, Decoded)).
