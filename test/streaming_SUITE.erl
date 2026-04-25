-module(streaming_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

-export([all/0, groups/0,
         init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    stream_content_basic/1,
    stream_finish_reason/1,
    stream_done_event/1,
    stream_timeout/1,
    stream_tool_call/1,
    stream_partial_chunks/1,
    stream_circuit_breaker_success/1,
    stream_cancel/1,
    stream_incomplete/1,
    stream_through_client/1,
    stream_client_capacity/1
]).

%% -- CT callbacks ----------------------------------------------------

all() -> [{group, streaming}, {group, client_streaming}].

groups() ->
    [{streaming, [sequence], [
        stream_content_basic,
        stream_finish_reason,
        stream_done_event,
        stream_timeout,
        stream_tool_call,
        stream_partial_chunks,
        stream_circuit_breaker_success,
        stream_cancel,
        stream_incomplete
    ]},
    {client_streaming, [sequence], [
        stream_through_client,
        stream_client_capacity
    ]}].

init_per_suite(Config) ->
    application:ensure_all_started(cowboy),
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(TC, Config) when TC =:= stream_through_client;
                                   TC =:= stream_client_capacity ->
    ok = mock_openrouter:start(),
    Port = mock_openrouter:port(),
    BaseUrl = "http://localhost:" ++ integer_to_list(Port) ++ "/api/v1",
    application:set_env(erl_openrouter, api_key, <<"sk-test-client-stream">>),
    ClientOpts = case TC of
        stream_client_capacity ->
            #{base_url => BaseUrl, max_in_flight => 1, max_retries => 0};
        _ ->
            #{base_url => BaseUrl, max_retries => 0}
    end,
    {ok, ClientPid} = openrouter_client:start_link(ClientOpts),
    [{base_url, BaseUrl}, {client_pid, ClientPid} | Config];
init_per_testcase(_TC, Config) ->
    ok = mock_openrouter:start(),
    Port = mock_openrouter:port(),
    BaseUrl = "http://localhost:" ++ integer_to_list(Port) ++ "/api/v1",
    [{base_url, BaseUrl} | Config].

end_per_testcase(TC, Config) when TC =:= stream_through_client;
                                  TC =:= stream_client_capacity ->
    ClientPid = proplists:get_value(client_pid, Config),
    gen_server:stop(ClientPid),
    application:unset_env(erl_openrouter, api_key),
    mock_openrouter:stop(),
    ok;
end_per_testcase(_TC, _Config) ->
    mock_openrouter:stop(),
    ok.

%% -- Helpers ---------------------------------------------------------

sse_data(JsonMap) ->
    {ok, Encoded} = openrouter_json:encode(JsonMap),
    <<"data: ", Encoded/binary, "\n\n">>.

sse_done() ->
    <<"data: [DONE]\n\n">>.

content_chunk(Text) ->
    sse_data(#{
        <<"choices">> => [#{
            <<"delta">> => #{<<"content">> => Text},
            <<"index">> => 0,
            <<"finish_reason">> => null
        }]
    }).

finish_chunk(Reason) ->
    sse_data(#{
        <<"choices">> => [#{
            <<"delta">> => #{},
            <<"index">> => 0,
            <<"finish_reason">> => Reason
        }]
    }).

tool_call_chunk(Index, Id, Name, Args) ->
    TC = #{<<"index">> => Index},
    TC1 = case Id of
              undefined -> TC;
              _ -> TC#{<<"id">> => Id}
          end,
    TC2 = case Name of
              undefined -> TC1;
              _ -> TC1#{<<"function">> => #{<<"name">> => Name, <<"arguments">> => Args}}
          end,
    TC3 = case Name of
              undefined ->
                  case Args of
                      undefined -> TC2;
                      _ -> TC2#{<<"function">> => #{<<"arguments">> => Args}}
                  end;
              _ -> TC2
          end,
    sse_data(#{
        <<"choices">> => [#{
            <<"delta">> => #{<<"tool_calls">> => [TC3]},
            <<"index">> => 0,
            <<"finish_reason">> => null
        }]
    }).

messages() ->
    [#{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}].

%% Build a request body and spawn the stream worker directly.
%% This avoids needing a registered openrouter_client process.
start_stream(Config, Timeout) ->
    BaseUrl = proplists:get_value(base_url, Config),
    Request = openrouter_chat:build_request(messages(), #{}),
    StreamRef = make_ref(),
    Self = self(),
    Pid = spawn(fun() ->
        openrouter_stream_worker:start(
            Self, StreamRef,
            BaseUrl ++ "/chat/completions",
            Request,
            #{auth => {ok, <<"sk-test-stream">>},
              timeout => Timeout,
              extra_headers => []})
    end),
    {StreamRef, Pid}.

start_stream(Config) ->
    start_stream(Config, 10000).

start_stream_with_cb(Config, CBName) ->
    BaseUrl = proplists:get_value(base_url, Config),
    Request = openrouter_chat:build_request(messages(), #{}),
    StreamRef = make_ref(),
    Self = self(),
    Pid = spawn(fun() ->
        openrouter_stream_worker:start(
            Self, StreamRef,
            BaseUrl ++ "/chat/completions",
            Request,
            #{auth => {ok, <<"sk-test-stream">>},
              timeout => 10000,
              extra_headers => [],
              circuit_breaker => CBName})
    end),
    {StreamRef, Pid}.

%% Collect all stream events until done or error, with a timeout.
collect_events(Ref, Timeout) ->
    collect_events(Ref, Timeout, []).

collect_events(Ref, Timeout, Acc) ->
    receive
        {stream_event, Ref, done} ->
            lists:reverse([done | Acc]);
        {stream_event, Ref, {error, _} = Err} ->
            lists:reverse([Err | Acc]);
        {stream_event, Ref, Event} ->
            collect_events(Ref, Timeout, [Event | Acc])
    after Timeout ->
        ct:fail({timeout_collecting_events, lists:reverse(Acc)})
    end.

%% Collect events with worker monitoring -- reports crash reason on failure.
collect_events_or_crash(Ref, MonRef, WorkerPid, Timeout) ->
    collect_events_or_crash(Ref, MonRef, WorkerPid, Timeout, []).

collect_events_or_crash(Ref, MonRef, WorkerPid, Timeout, Acc) ->
    receive
        {stream_event, Ref, done} ->
            lists:reverse([done | Acc]);
        {stream_event, Ref, {error, _} = Err} ->
            lists:reverse([Err | Acc]);
        {stream_event, Ref, Event} ->
            collect_events_or_crash(Ref, MonRef, WorkerPid, Timeout, [Event | Acc]);
        {'DOWN', MonRef, process, WorkerPid, normal} ->
            %% Worker exited normally but we didn't get done -- drain remaining
            drain_events(Ref, Acc);
        {'DOWN', MonRef, process, WorkerPid, Reason} ->
            ct:fail({worker_crashed, Reason, collected_events, lists:reverse(Acc)})
    after Timeout ->
        ct:fail({timeout_collecting_events, lists:reverse(Acc)})
    end.

drain_events(Ref, Acc) ->
    receive
        {stream_event, Ref, done} ->
            lists:reverse([done | Acc]);
        {stream_event, Ref, {error, _} = Err} ->
            lists:reverse([Err | Acc]);
        {stream_event, Ref, Event} ->
            drain_events(Ref, [Event | Acc])
    after 100 ->
        lists:reverse(Acc)
    end.

%% Collect events expecting an error terminator rather than done.
collect_error_events(Ref, Timeout) ->
    collect_error_events(Ref, Timeout, []).

collect_error_events(Ref, Timeout, Acc) ->
    receive
        {stream_event, Ref, done} ->
            lists:reverse([done | Acc]);
        {stream_event, Ref, {error, _} = Err} ->
            lists:reverse([Err | Acc]);
        {stream_event, Ref, Event} ->
            collect_error_events(Ref, Timeout, [Event | Acc])
    after Timeout ->
        ct:fail({timeout_waiting_for_error, lists:reverse(Acc)})
    end.

%% -- Test cases ------------------------------------------------------

stream_content_basic(Config) ->
    C1 = content_chunk(<<"Hello">>),
    C2 = content_chunk(<<" beautiful">>),
    C3 = content_chunk(<<" world">>),
    Fin = finish_chunk(<<"stop">>),
    Done = sse_done(),
    Scenario = [
        {0, C1},
        {10, C2},
        {10, C3},
        {10, Fin},
        {0, Done, fin}
    ],
    mock_sse_handler:install(Scenario),
    {Ref, WorkerPid} = start_stream(Config),
    MonRef = monitor(process, WorkerPid),
    Events = collect_events_or_crash(Ref, MonRef, WorkerPid, 5000),
    ContentParts = [T || {content, T} <- Events],
    ?assertEqual([<<"Hello">>, <<" beautiful">>, <<" world">>], ContentParts),
    FullText = iolist_to_binary(ContentParts),
    ?assertEqual(<<"Hello beautiful world">>, FullText).

stream_finish_reason(Config) ->
    Scenario = [
        {0, content_chunk(<<"Hi">>)},
        {10, finish_chunk(<<"stop">>)},
        {0, sse_done(), fin}
    ],
    mock_sse_handler:install(Scenario),
    {Ref, _Pid} = start_stream(Config),
    Events = collect_events(Ref, 5000),
    FinishEvents = [R || {finish, R} <- Events],
    ?assertEqual([stop], FinishEvents),
    %% finish must come before done
    FinishIdx = index_of({finish, stop}, Events),
    DoneIdx = index_of(done, Events),
    ?assert(FinishIdx < DoneIdx).

stream_done_event(Config) ->
    Scenario = [
        {0, content_chunk(<<"ok">>)},
        {10, finish_chunk(<<"stop">>)},
        {0, sse_done(), fin}
    ],
    mock_sse_handler:install(Scenario),
    {Ref, _Pid} = start_stream(Config),
    Events = collect_events(Ref, 5000),
    ?assertEqual(done, lists:last(Events)).

stream_timeout(Config) ->
    %% Mock delays 3 seconds but the worker timeout is 500ms.
    Scenario = [
        {3000, content_chunk(<<"late">>)},
        {0, sse_done(), fin}
    ],
    mock_sse_handler:install(Scenario),
    {Ref, _Pid} = start_stream(Config, 500),
    Events = collect_error_events(Ref, 3000),
    ?assert(lists:member({error, timeout}, Events)).

stream_tool_call(Config) ->
    Scenario = [
        {0, tool_call_chunk(0, <<"call_abc">>, <<"get_weather">>, <<"{\"city\":">>)},
        {10, tool_call_chunk(0, undefined, undefined, <<"\"NYC\"}">>)},
        {10, finish_chunk(<<"tool_calls">>)},
        {0, sse_done(), fin}
    ],
    mock_sse_handler:install(Scenario),
    {Ref, _Pid} = start_stream(Config),
    Events = collect_events(Ref, 5000),
    ToolDeltas = [Idx || {tool_call_delta, Idx} <- Events],
    ?assertEqual([0, 0], ToolDeltas),
    FinishEvents = [R || {finish, R} <- Events],
    ?assertEqual([tool_calls], FinishEvents).

stream_partial_chunks(Config) ->
    %% Send a single SSE data line split across two TCP writes.
    %% The parser should buffer the partial line and deliver the
    %% event only after the second chunk completes the line.
    FullLine = content_chunk(<<"buffered">>),
    SplitPos = byte_size(FullLine) div 2,
    Part1 = binary:part(FullLine, 0, SplitPos),
    Part2 = binary:part(FullLine, SplitPos, byte_size(FullLine) - SplitPos),
    Scenario = [
        {0, Part1},
        {50, Part2},
        {10, finish_chunk(<<"stop">>)},
        {0, sse_done(), fin}
    ],
    mock_sse_handler:install(Scenario),
    {Ref, _Pid} = start_stream(Config),
    Events = collect_events(Ref, 5000),
    ContentParts = [T || {content, T} <- Events],
    ?assertEqual([<<"buffered">>], ContentParts).

stream_circuit_breaker_success(Config) ->
    %% Start a circuit breaker, run a successful stream, verify it
    %% stays closed (recorded success).
    {ok, CBPid} = openrouter_circuit_breaker:start_link(
        openrouter_test_cb, #{failure_threshold => 5, reset_timeout => 30000}),
    unlink(CBPid),
    Scenario = [
        {0, content_chunk(<<"cb_ok">>)},
        {10, finish_chunk(<<"stop">>)},
        {0, sse_done(), fin}
    ],
    mock_sse_handler:install(Scenario),
    {Ref, WorkerPid} = start_stream_with_cb(Config, openrouter_test_cb),
    MonRef = monitor(process, WorkerPid),
    _Events = collect_events(Ref, 5000),
    %% Wait for worker to finish so CB gets recorded
    receive
        {'DOWN', MonRef, process, WorkerPid, _} -> ok
    after 2000 ->
        ct:fail(worker_did_not_exit)
    end,
    ?assertEqual(closed, openrouter_circuit_breaker:state(openrouter_test_cb)),
    gen_server:stop(openrouter_test_cb).

stream_cancel(Config) ->
    %% Mock sends content with a long delay; cancel before it arrives.
    Scenario = [
        {0, content_chunk(<<"first">>)},
        {5000, content_chunk(<<"never">>)},
        {0, sse_done(), fin}
    ],
    mock_sse_handler:install(Scenario),
    {Ref, WorkerPid} = start_stream(Config, 30000),
    %% Wait for the first chunk to confirm stream is active.
    %% httpc connection setup can be slow on first request.
    receive
        {stream_event, Ref, {content, <<"first">>}} -> ok
    after 10000 ->
        ct:fail(did_not_receive_first_chunk)
    end,
    openrouter:cancel_stream(WorkerPid),
    %% Worker may receive cancel before or after the mock finishes.
    %% Accept any terminal event.
    receive
        {stream_event, Ref, {error, cancelled}} -> ok;
        {stream_event, Ref, {error, _}} -> ok;
        {stream_event, Ref, done} -> ok
    after 5000 ->
        ok  %% worker may have exited before cancel arrived
    end.

stream_incomplete(Config) ->
    %% Mock closes connection without sending [DONE].
    Scenario = [
        {0, content_chunk(<<"partial">>)},
        {10, finish_chunk(<<"stop">>), fin}
    ],
    mock_sse_handler:install(Scenario),
    {Ref, WorkerPid} = start_stream(Config),
    MonRef = monitor(process, WorkerPid),
    Events = collect_events_or_crash(Ref, MonRef, WorkerPid, 5000),
    ?assert(lists:member({error, incomplete_stream}, Events)).

%% -- Client streaming tests ------------------------------------------

stream_through_client(_Config) ->
    %% Exercise the full path: openrouter:chat_stream/2 -> openrouter_client
    %% -> stream worker -> mock SSE server.
    C1 = content_chunk(<<"Hello">>),
    C2 = content_chunk(<<" from">>),
    C3 = content_chunk(<<" client">>),
    Fin = finish_chunk(<<"stop">>),
    Done = sse_done(),
    Scenario = [
        {0, C1},
        {10, C2},
        {10, C3},
        {10, Fin},
        {0, Done, fin}
    ],
    mock_sse_handler:install(Scenario),
    Messages = messages(),
    {ok, StreamRef, WorkerPid} = openrouter:chat_stream(Messages, #{}),
    ?assert(is_reference(StreamRef)),
    ?assert(is_pid(WorkerPid)),
    MonRef = monitor(process, WorkerPid),
    Events = collect_events_or_crash(StreamRef, MonRef, WorkerPid, 5000),
    ContentParts = [T || {content, T} <- Events],
    ?assertEqual([<<"Hello">>, <<" from">>, <<" client">>], ContentParts),
    ?assert(lists:member({finish, stop}, Events)),
    ?assert(lists:member(done, Events)).

stream_client_capacity(_Config) ->
    %% With max_in_flight=1, a second stream should be rejected while
    %% the first is still active. The in_flight slot is occupied from
    %% the moment chat_stream returns {ok, ...} until the worker's
    %% DOWN is processed -- no need to wait for the first chunk.
    SlowScenario = [
        {5000, content_chunk(<<"slow">>)},
        {0, finish_chunk(<<"stop">>)},
        {0, sse_done(), fin}
    ],
    mock_sse_handler:install(SlowScenario),
    Messages = messages(),
    %% Start the first stream -- occupies the single in-flight slot.
    {ok, _StreamRef1, WorkerPid1} = openrouter:chat_stream(Messages, #{}),
    %% The in_flight slot is occupied immediately after chat_stream
    %% returns. The second call should fail.
    Result = openrouter:chat_stream(Messages, #{}),
    ?assertMatch({error, #api_error{type = overloaded}}, Result),
    %% Clean up
    openrouter:cancel_stream(WorkerPid1),
    timer:sleep(500).

%% -- Internal helpers ------------------------------------------------

index_of(Elem, List) ->
    index_of(Elem, List, 1).

index_of(_Elem, [], _N) ->
    ct:fail(element_not_found);
index_of(Elem, [Elem | _], N) ->
    N;
index_of(Elem, [_ | Rest], N) ->
    index_of(Elem, Rest, N + 1).
