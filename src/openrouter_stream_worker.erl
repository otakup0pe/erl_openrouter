-module(openrouter_stream_worker).
%% @private
%% Internal module -- spawned by openrouter_client for streaming requests.

-export([start/5]).

-include("openrouter.hrl").

-record(ws, {
    request_id :: reference(),
    caller :: pid(),
    stream_ref :: reference(),
    parser :: openrouter_stream:state(),
    idle_timeout :: pos_integer(),
    circuit_breaker :: atom() | pid() | undefined
}).

-spec start(pid(), reference(), string(), binary(), map()) -> ok.
start(CallerPid, StreamRef, Url, Request, Opts) ->
    StreamRequest = inject_stream_flag(Request),
    Auth = maps:get(auth, Opts),
    Timeout = maps:get(timeout, Opts),
    ExtraHeaders = maps:get(extra_headers, Opts, []),
    CB = maps:get(circuit_breaker, Opts, undefined),

    case openrouter_http:post_stream(Url, StreamRequest, Auth, Timeout, ExtraHeaders) of
        {ok, RequestId} ->
            State = #ws{
                request_id = RequestId,
                caller = CallerPid,
                stream_ref = StreamRef,
                parser = openrouter_stream:new(),
                idle_timeout = Timeout,
                circuit_breaker = CB
            },
            loop(State);
        {error, Reason} ->
            record_cb_failure(CB),
            CallerPid ! {stream_event, StreamRef, {error, Reason}},
            ok
    end.

loop(#ws{request_id = ReqId, caller = Caller, stream_ref = Ref,
         parser = Parser, idle_timeout = Timeout, circuit_breaker = CB} = State) ->
    receive
        {http, {ReqId, stream_start, _Headers, _StatusCode}} ->
            loop(State);
        {http, {ReqId, stream_start, _Headers}} ->
            loop(State);
        {http, {ReqId, stream, Chunk}} ->
            {Events, NewParser} = openrouter_stream:feed(Chunk, Parser),
            lists:foreach(fun(Ev) ->
                Caller ! {stream_event, Ref, Ev}
            end, Events),
            loop(State#ws{parser = NewParser});
        {http, {ReqId, stream_end, _Headers}} ->
            case openrouter_stream:done(Parser) of
                true ->
                    record_cb_success(CB);
                false ->
                    Caller ! {stream_event, Ref, {error, incomplete_stream}},
                    record_cb_failure(CB)
            end;
        {http, {ReqId, {error, Reason}}} ->
            Caller ! {stream_event, Ref, {error, Reason}},
            record_cb_failure(CB);
        cancel ->
            httpc:cancel_request(ReqId),
            Caller ! {stream_event, Ref, {error, cancelled}}
    after Timeout ->
        httpc:cancel_request(ReqId),
        Caller ! {stream_event, Ref, {error, timeout}},
        record_cb_failure(CB)
    end.

-spec inject_stream_flag(binary()) -> binary().
inject_stream_flag(RequestBody) when is_binary(RequestBody) ->
    case openrouter_json:decode(RequestBody) of
        {ok, Map} when is_map(Map) ->
            {ok, Encoded} = openrouter_json:encode(Map#{<<"stream">> => true}),
            Encoded;
        _ ->
            RequestBody
    end.

record_cb_success(undefined) -> ok;
record_cb_success(CB) -> openrouter_circuit_breaker:record_success(CB).

record_cb_failure(undefined) -> ok;
record_cb_failure(CB) -> openrouter_circuit_breaker:record_failure(CB).
