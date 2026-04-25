-module(mock_sse_handler).
%% Mock SSE handler for streaming CT tests.
%%
%% Provides configurable SSE response scenarios via ETS. Each scenario
%% is a list of {delay_ms, iodata()} tuples describing what to send
%% and when. The handler validates that the request body contains
%% "stream": true before streaming.

-export([install/1, install/2]).

%% @doc Install a streaming handler into mock_openrouter.
%% Scenario is a list of {DelayMs, ChunkBinary} tuples.
%% Each chunk is sent via cowboy_req:stream_body after the delay.
install(Scenario) ->
    install(Scenario, 200).

install(Scenario, StatusCode) ->
    Fun = fun(_Method, chat_completions, ReqBody, _Headers, Req0) ->
        case validate_stream_flag(ReqBody) of
            true ->
                Req1 = cowboy_req:stream_reply(
                    StatusCode,
                    #{<<"content-type">> => <<"text/event-stream">>,
                      <<"cache-control">> => <<"no-cache">>},
                    Req0),
                send_chunks(Scenario, Req1),
                {ok, Req1, chat_completions};
            false ->
                Req1 = cowboy_req:reply(400,
                    #{<<"content-type">> => <<"application/json">>},
                    <<"{\"error\":\"stream flag not set\"}">>,
                    Req0),
                {ok, Req1, chat_completions}
        end;
    (_Method, Endpoint, _ReqBody, _Headers, Req0) ->
        Req1 = cowboy_req:reply(404,
            #{<<"content-type">> => <<"application/json">>},
            <<"{\"error\":\"not found\"}">>,
            Req0),
        {ok, Req1, Endpoint}
    end,
    mock_openrouter:set_handler(Fun).

%% Internal

validate_stream_flag(ReqBody) ->
    case openrouter_json:decode(ReqBody) of
        {ok, #{<<"stream">> := true}} -> true;
        _ -> false
    end.

send_chunks([], _Req) ->
    ok;
send_chunks([{DelayMs, Chunk} | Rest], Req) ->
    case DelayMs > 0 of
        true -> timer:sleep(DelayMs);
        false -> ok
    end,
    cowboy_req:stream_body(Chunk, nofin, Req),
    send_chunks(Rest, Req);
send_chunks([{DelayMs, Chunk, fin} | _Rest], Req) ->
    case DelayMs > 0 of
        true -> timer:sleep(DelayMs);
        false -> ok
    end,
    cowboy_req:stream_body(Chunk, fin, Req).
